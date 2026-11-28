// The link order probe; see include/CmuxNextLinkOrder.h. Compiled only into a CMUX_LINK_ORDER_PROBE build:
// any other build gets an empty object (no initializer, no symbol), so a shipped app runs nothing of it.
#ifdef CMUX_LINK_ORDER_PROBE

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// The probe's own functions are never instrumented: a guard call inside the guard would recurse.
#define CMUX_LO_NO_COVERAGE __attribute__((no_sanitize("coverage"), used))

// First calls, in order. 4M functions is more than the app has; past it the rest are dropped.
enum { kCapacity = 1 << 22 };
static void *g_first_calls[kCapacity];
static _Atomic size_t g_count;
static _Atomic int g_written;

// Each instrumented function has one guard; give every guard a non-zero id once, per image.
CMUX_LO_NO_COVERAGE void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    static uint32_t next;
    if (start == stop || *start) return;
    for (uint32_t *guard = start; guard < stop; guard++) *guard = ++next;
}

// A function's first run records its address and zeroes its guard, so later runs return at once.
// Two threads racing on one guard can record it twice; link-order.py keeps the first.
CMUX_LO_NO_COVERAGE void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    if (!*guard) return;
    *guard = 0;
    size_t slot = atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    if (slot < kCapacity) g_first_calls[slot] = __builtin_return_address(0);
}

// One line per first call: the image's path, a tab, the address's offset from that image's Mach-O
// header in hex. The first writer wins (the timer or the process's exit).
CMUX_LO_NO_COVERAGE static void cmux_lo_write(void) {
    if (atomic_exchange(&g_written, 1)) return;
    const char *path = getenv("CMUX_LINK_ORDER_OUT");
    if (!path || !*path) return;
    FILE *out = fopen(path, "w");
    if (!out) return;
    size_t count = atomic_load(&g_count);
    if (count > kCapacity) count = kCapacity;
    for (size_t i = 0; i < count; i++) {
        Dl_info info;
        if (!g_first_calls[i] || !dladdr(g_first_calls[i], &info) || !info.dli_fname) continue;
        fprintf(out, "%s\t%lx\n", info.dli_fname,
                (unsigned long)((uintptr_t)g_first_calls[i] - (uintptr_t)info.dli_fbase));
    }
    fclose(out);
}

// $CMUX_LINK_ORDER_DUMP_MS (default 8000) after the image loaded: launch has drawn its first frame by then.
CMUX_LO_NO_COVERAGE static void *cmux_lo_timer(void *unused) {
    (void)unused;
    const char *ms = getenv("CMUX_LINK_ORDER_DUMP_MS");
    long wait_ms = ms && *ms ? strtol(ms, 0, 10) : 8000;
    if (wait_ms > 0) usleep((useconds_t)(wait_ms * 1000));
    cmux_lo_write();
    return 0;
}

CMUX_LO_NO_COVERAGE __attribute__((constructor)) static void cmux_lo_start(void) {
    if (!getenv("CMUX_LINK_ORDER_OUT")) return;
    atexit(cmux_lo_write);
    pthread_t thread;
    if (pthread_create(&thread, 0, cmux_lo_timer, 0) == 0) pthread_detach(thread);
}

#else
// ISO C wants a declaration in every file; a typedef adds no symbol.
typedef int cmux_next_link_order_off;
#endif
