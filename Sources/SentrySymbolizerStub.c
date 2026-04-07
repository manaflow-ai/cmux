/*
 * SentrySymbolizerStub.c
 *
 * Provides sentry__symbolize() which is referenced by sentry_scope.o inside
 * libghostty.a but was omitted from the archive during xcframework assembly
 * (static-library merging with libtool only pulls in object files that resolve
 * external references; sentry_symbolizer_unix.o is only referenced internally
 * within libsentry.a and therefore gets dropped).
 *
 * This implementation is functionally identical to the upstream
 * sentry-native sentry_symbolizer_unix.c (MIT License).
 */

#include <dlfcn.h>
#include <stdbool.h>
#include <string.h>

/* Mirror of sentry_frame_info_t from the sentry-native C SDK. */
typedef struct {
    const char *object_name;
    void *load_addr;
    void *symbol_addr;
    void *instruction_addr;
    const char *symbol;
    int lineno;
    const char *filename;
} sentry_frame_info_t;

bool
sentry__symbolize(
    void *addr, void (*func)(const sentry_frame_info_t *, void *), void *data)
{
    Dl_info info;
    if (dladdr(addr, &info) == 0) {
        return false;
    }

    sentry_frame_info_t frame_info;
    memset(&frame_info, 0, sizeof(frame_info));
    frame_info.load_addr = info.dli_fbase;
    frame_info.symbol_addr = info.dli_saddr;
    frame_info.instruction_addr = addr;
    frame_info.symbol = info.dli_sname;
    frame_info.object_name = info.dli_fname;
    func(&frame_info, data);
    return true;
}
