
;
; GZip compression library module based on the C library ZLib aka LibZ
; Copyright (C) 2013 Mikael More
; MIT license
;
; ## Example use
; (zlib-compress-u8vector-block '#u8(1 2 3 4)) => #u8(120 94 99 100 98 102 1 0 0 24 0 11)
;
; (zlib-decompress-u8vector-block '#u8(120 94 99 100 98 102 1 0 0 24 0 11) 100)
; => (values #f #t '#u8(1 2 3 4) 4)
;
; (zlib-decompress-u8vector-block-result '#u8(120 94 99 100 98 102 1 0 0 24 0 11) 100)
; => #u8(1 2 3 4)
;
; ## Clarification of the term 'gzip' and 'Gzip' generally and in this module
; LibZ is the primary implementation used for the 'gzip' compression that's everywhere, such as in
; the HTTP and SSL protocols and SWF files.
;
; This 'gzip' compression algorithm is not the same as the .gz file format produced by the gzip
; application though; the LibZ library by default produces another header format than that used
; by Gzip.
;
; It is within the scope of this module to provide any 'gzip' compression functionality, including
; that with ordinary LibZ headers as found in HTTP/SSL/SWF/etc. , and if found needed, the header
; format of the GZip application also;
;
; We don't bother too much about what LibZ provided for us in the first place, as its key value is
; compression and decompression using this one and the same algorithm.
;
; Within this module, by 'gzip' or 'Gzip' compression, we will mean compression using this
; algorithm.
;
; For notes on LibZ vs GZip header differences, see
; http://stackoverflow.com/questions/1838699/how-can-i-decompress-a-gzip-stream-with-zlib .
;
; ## Use on Microsoft Windows
; The MingW binaries for ZLib are at http://sourceforge.net/projects/mingw/files/MinGW/Extension/zlib/ ,
; the *-dll-1.tar.lzma file is for the DLL and the *-dev.tar.lzma is for the headers and library file.
;
; ## Libz manual error note
; During the development of this module, an error was found in Libz's manual (!). It says for
; uncompress():
;
;      "Upon exit, destLen is the actual size of the compressed buffer."
;
; This is not correct, it's the size of the *un*compressed buffer, as shown by their uncompr.c with
; all clarity:
;
;      *destLen = stream.total_out;
;
; ## References
; API definition at: http://www.gzip.org/zlib/manual.html
; Tutorial at: http://www.zlib.net/zlib_how.html
;
; Chicken: http://wiki.call-cc.org/eggref/4/zlib , with its main code at
;          http://code.call-cc.org/svn/chicken-eggs/release/4/zlib/trunk/
;
; Racket LibZ module: http://planet.racket-lang.org/display.ss?package=gzip.plt&owner=soegaard
;
; ## TODO
;  * For SMP Gambit support: Replace the boxes used with the FFI with ___STILL variants!
;

(compile-options ld-options-prelude: "-lz" force-compile: #t)

(c-declare #<<c-declare-end

// malloc
#include <stdlib.h>
// memcpy
#include <string.h>
#include <zlib.h>

// For some debug printouts, can be commented out.
#include <stdio.h>

c-declare-end
)

; This delivers LibZ's "conveniency" zlib u8vector compression export.
;
; It takes an u8vector and returns a compressed u8vector.
;
; We call it "-block" to emphasise that this is an operation that works in one step and allows no
; Gambit scheduler interrupts during its execution.
;
; (We can take any input and construct a result out of it in one block as we can calculate the max
; size of the output reliably.)
(define (zlib-compress-u8vector-block u8v #!optional (level 5))
  (zlib-compress-subu8vector-block u8v 0 (u8vector-length u8v) level))

; "
(define (zlib-compress-subu8vector-block u8v start end #!optional (level 5))
  ((c-lambda (scheme-object unsigned-int64 unsigned-int64 unsigned-int16) scheme-object #<<c-lambda-end

___SCMOBJ inputu8v    = ___arg1;
int start             = ___arg2;
int end               = ___arg3;
int compressionlevel  = ___arg3;
Bytef* inputu8v_bytes = ___CAST(Bytef*,&___FETCH_U8(___BODY(inputu8v),___INT(0))) + start;

int input_bytes = end - start;

uLongf buffer_bytes = ((input_bytes * 21) / 20) + 1 + 12;  // Target buffer must be 0.1% + 12 bytes bigger than the source, here we add at least 5% + 12.
Bytef* buffer = (Bytef*) malloc(buffer_bytes);
int r = compress2(buffer,&buffer_bytes,inputu8v_bytes,input_bytes,compressionlevel);
if (r == Z_OK) {
     // (compress2 has now set buffer_bytes to the number of bytes of generated compressed data)
     ___SCMOBJ outputu8v = ___EXT(___alloc_scmobj)(___sU8VECTOR,buffer_bytes,___MOVABLE0);
     // TODO: Error check
     ___EXT(___release_scmobj) (outputu8v);
     void* outputu8v_bytes = ___CAST(void*,&___FETCH_U8(___BODY(outputu8v),___INT(0)));
     memcpy(outputu8v_bytes,buffer,buffer_bytes);
     ___result = outputu8v;
} else
     ___result = ___FAL;

free(buffer);

c-lambda-end
             ) u8v start end level))

; This delivers LibZ's "conveniency" zlib u8vector decompression export.
;
; We deliver it a bit more for completeness than for anything else, because except for
;  * performing in one block without any interrupt for Gambit's scheduler, it also
;  * requires us to know the output size from the beginning as no memory allocation is allowed to
;    be done dynamically during the course of the compression - at least kind-of, we can
;    guess a too high number of course, that works well for several usecases - and
;  * it only allows LibZ-format input not GZip which is also possible with this module.
;
; Please note that these limitations and characteristics have some impact on how we can make the
; Scheme procedure definition for this one.
;
; Given a reading the manual for LibZ's inflate() (in zlib_how.html) procedure and the
; clarification from LibZ's uncompr.c that uncompress() is just a simple wrapper over it, it is
; clear that if you provide a too short output buffer, then all of the output buffer provided will
; be filled up indeed, with exactly as much of the uncompressed output that it can handle. This has
; also been double-checked by practical test.
;
; Please note that this procedure *not* reports at what byte position in the source u8vector that
; the compressed data ended. Use of the other API:s is needed for this.
;
; We call it "-block" to emphasise that this is an operation that works in one step and allows no
; Gambit scheduler interrupts during its execution, and also no dynamic memory allocation during
; its course of execution.
;
; Our export here is a bit different from the typical |read-subu8vector| etc., because we want
; this procedure to by default create a new u8vector for its output, as this is like a general
; convenience.
;
; (zlib-decompress-u8vector-block zlib-u8v result-u8v-end
;                                 #!optional result-u8v (zlib-u8v-start 0) zlib-u8v-end (result-u8v-start 0)
;                                            (trim-result? 'dfl))
; => values (failure? all-decompressed? result-u8v decompressed-data-ended-at-result-u8v-index)
;
; where
;
; (Input:)
;      zlib-u8v = The u8vector containing the gzip-compressed data.
;
;                 Note that the u8vector is allowed to contain other gzip streams and non-gzip data
;                 both before and after this one; decompression stops automatically at the gzip
;                 stream's end, which is something the algorithm takes care of by itself.
;
;      result-u8v-end = If result-u8v is not provided:
;                       The size of the buffer that this procedure should allocate.
;                       result-u8v-end - result-u8v-start will be the max bytes that this
;                       procedure call can decompress.
;
;                       If result-u8v is provided:
;                       The byte position in result-u8v right after the byte at which decompression
;                       will end.
;
;      result-u8v = #f       = This procedure allocates the output structure to decompress into. At
;                              the time of allocation and decompression it will be |result-u8v-end|
;                              bytes.
;                   u8vector = This procedure will decompress into this u8vector.
;
;      zlib-u8v-start = The byte position in zlib-u8v that decompression work will start at, integer.
;
;      zlib-u8v-end = #f = Decompress up to the end of zlib-u8v
;                     integer = Decompress until the byte position right before this one.
;
;      result-u8v-start = The byte position in result-u8v (independent of if result-u8v is generated by
;                         this procedure or provided as an argument) at which decompression will start.
;
;      trim-result? = 'dfl = Auto: If result-u8v was provided, then no, because we presume the result-u8v
;                                  has a broader content than the result of this uncompress operation and
;                                  should therefore be let remain intact.
; 
;                                  And, if result-u8v was not provided, then yes, because we presume that
;                                  result-u8v-end was passed as a max buffer size to ensure all compressed
;                                  data was gotten successfully, while what's wanted as return value is
;                                  the actual decompressed data only.
;                     #t   = Yes, |u8vector-shrink!| result-u8v to finish where the uncompressed data
;                            finishes.
;                     #f   = No, keep result-u8v intact as it was when given to this procedure/allocated.
;
; (Output:)
;      failure? = #f       = Not failure, zero or more bytes were successfully decompressed,
;                            please refer to all-decompressed? for more info.
;                 'corrupt = The gzip input data was corrupt.
;                 'no-mem  = Out of memory during decompression process.
;                 'other   = Other. This should never happen.
;      all-decompressed? = Boolean, #f if there was more compressed input data than fit into [the
;                          output interval in] result-u8v
;      result-u8v = The u8vector containing the resulting data. (If result-u8v was provided on input,
;                   then this is the same object reference as that.)
;      decompressed-data-ended-at-result-u8v-index = The byte position in result-u8v right after the one at which the
;                                                    decompressed data ended. If trim-result? is set, which it is by default
;                                                    if no result-u8v was provided, then this equals the length of the
;                                                    returned u8vector.
;

(define (zlib-decompress-u8vector-block-result . a)
  (call-with-values
   (lambda () (apply zlib-decompress-u8vector-block a))
   (lambda (failure? all-decompressed? result-u8v decompressed-data-ended-at-result-u8v-index)
     (and (not failure?) result-u8v))))

(define (zlib-decompress-u8vector-block zlib-u8v result-u8v-end
                                        #!key result-u8v (zlib-u8v-start 0) zlib-u8v-end (result-u8v-start 0) (trim-result? 'dfl))

  (let (

        (trim-result? (if (eq? trim-result? 'dfl) (if result-u8v #f #t) trim-result?))

        (result-u8v (or result-u8v (make-u8vector result-u8v-end)))

        ; We share mutable variables with the c-lambda in the form of box variables.
        ;
        ; XXX With SMP Gambit, the current boxes that are MOVABLE will become UNSAFE and should be replaced with STILL variants.
        (failure?-box                                    (box 3 )) ; = 'other
        (all-decompressed?-box                           (box #f))
        (decompressed-data-ended-at-result-u8v-index-box (box #f))

        )

    ((c-lambda (scheme-object unsigned-int64 scheme-object unsigned-int64 unsigned-int64 unsigned-int64
                scheme-object scheme-object scheme-object) void #<<c-lambda-end

___SCMOBJ zlib_u8v         = ___arg1;
___U64    result_u8v_end   = ___arg2;
___SCMOBJ result_u8v       = ___arg3;
___U64    zlib_u8v_start   = ___arg4;
___U64    zlib_u8v_end     = ___arg5;
___U64    result_u8v_start = ___arg6;

___SCMOBJ failure_box                                     = ___arg7;
___SCMOBJ all_decompressed_box                            = ___arg8;
___SCMOBJ decompressed_data_ended_at_result_u8v_index_box = ___arg9;

Bytef* input_u8v_bytes  = ___CAST(Bytef*,&___FETCH_U8(___BODY(zlib_u8v  ),___INT(0))) + zlib_u8v_start  ;

Bytef* output_u8v_bytes = ___CAST(Bytef*,&___FETCH_U8(___BODY(result_u8v),___INT(0))) + result_u8v_start;

uLongf destLen = result_u8v_end - result_u8v_start;

// printf("Bytes: %i %i %i %i %i\n",input_u8v_bytes[0],input_u8v_bytes[1],input_u8v_bytes[2],input_u8v_bytes[3],input_u8v_bytes[4]);

// printf("zlib_u8v_start = %i . result_u8v_start = %i .\n",zlib_u8v_start,result_u8v_start);
// printf("all_decompressed_box ptr = %i . compressed_data_ended_at_zlib_u8v_index_box ptr = %i .\n",all_decompressed_box,compressed_data_ended_at_zlib_u8v_index_box);
// printf("Invoking uncompress with %i , %i , %i , %i .\n",(long) output_u8v_bytes,destLen,(long) input_u8v_bytes,zlib_u8v_end - zlib_u8v_start);

int r = uncompress(output_u8v_bytes             , // Bytef *dest
                   &destLen                     , // uLongf *destLen
                   input_u8v_bytes              , // const Bytef *source
                   zlib_u8v_end - zlib_u8v_start  // uLong sourceLen
                   );
switch (r) {
     case Z_OK        : // Success
     case Z_BUF_ERROR : // Not enough room in output buffer - we categorize this as success too

          // printf("Success!\n");
          ___SETBOX(failure_box,___FIX(0));

          ___SETBOX(all_decompressed_box,(r == Z_OK) ? ___TRU : ___FAL);

          // For what value destLen is updated to on return from uncompress(), please see the section
          // in the header comments that are devoted to this topic.
          ___SETBOX(decompressed_data_ended_at_result_u8v_index_box,___FIX(result_u8v_start + destLen));

          break;
     case Z_DATA_ERROR: // Data corrupt
          // printf("Data corrupt.\n");
          ___SETBOX(failure_box,1);
          break;
     case Z_MEM_ERROR : // Out of memory
          // printf("Out of memory.\n");
          ___SETBOX(failure_box,2);
          break;
     case Z_STREAM_ERROR : // Out of memory
          // printf("Got stream error - that shouldn't happen!\n");
          break;
     default          : // Other error - this should never happen, from reading the manual.
                        // failure_box already set right, so no need to handle it even.
          // printf("Got other error code %i.\n",r);
          ;
}

// printf("Returning.\n");

c-lambda-end
             )

     zlib-u8v result-u8v-end result-u8v zlib-u8v-start (or zlib-u8v-end (u8vector-length zlib-u8v)) result-u8v-start

     failure?-box all-decompressed?-box decompressed-data-ended-at-result-u8v-index-box

     )

    (let ((failure? (case (unbox failure?-box) ((0) #f) ((1) 'corrupt) ((2) 'no-mem) (else 'other)))
          (decompressed-data-ended-at-result-u8v-index (unbox decompressed-data-ended-at-result-u8v-index-box)))

      (if trim-result? (u8vector-shrink! result-u8v decompressed-data-ended-at-result-u8v-index))

      (values failure?
              (unbox all-decompressed?-box)
              (and (not failure?) result-u8v)
              (and (not failure?) decompressed-data-ended-at-result-u8v-index)
              )
      )))

