#ifndef CMUX_BUNDLED_ZLIB_H
#define CMUX_BUNDLED_ZLIB_H
#include <stddef.h>
typedef unsigned char Byte;
typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;
typedef void *voidpf;
typedef struct z_stream_s { Bytef *next_in; uInt avail_in; uLong total_in; Bytef *next_out; uInt avail_out; uLong total_out; char *msg; voidpf state; voidpf (*zalloc)(voidpf, unsigned int, unsigned int); voidpf (*zfree)(voidpf, voidpf); voidpf opaque; int data_type; uLong adler; uLong reserved; } z_stream;
#define Z_OK 0
#define Z_STREAM_END 1
#define Z_BUF_ERROR (-5)
#define Z_DEFAULT_COMPRESSION (-1)
#define Z_SYNC_FLUSH 2
#define ZLIB_VERSION "1.2.11"
int inflateInit_(z_stream *, const char *, int);
int inflateEnd(z_stream *);
int inflate(z_stream *, int);
int deflateInit_(z_stream *, int, const char *, int);
int deflateEnd(z_stream *);
int deflate(z_stream *, int);
#endif
