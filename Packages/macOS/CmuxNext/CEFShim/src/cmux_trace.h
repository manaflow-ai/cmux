/* Release trace ring v1 writer and crash-key page, header-only C11 (plans/cmux-next/trace.md,
 * "Release trace ring v1"). The Chromium host and the shim write their black box with it, and it is
 * the reference for the Ghostty Zig hook. The Swift ring (CmuxNextTrace, task 003) and the Rust
 * cmux-trace crate (task 009) write the same bytes: tests/ring.rs and cmux_trace_test.c build the
 * same golden ring and compare it with Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace.
 *
 * The model is Perfetto's shared memory buffer (src/tracing/core/shared_memory_abi.h), as in Chrome's
 * TraceLog: each thread owns one 1 KiB chunk at a time, a chunk still owned by another thread is
 * skipped and never shared, a record is published with a per-slot seqlock, the ring overwrites its
 * oldest chunks, and a writer drops a record rather than wait (BufferExhaustedPolicy::kDrop).
 *
 * What the header does not do: it allocates nothing, maps nothing, opens nothing and takes no lock.
 * The caller gives every ring its memory (zeroed: a heap block from the first instruction, later a
 * MAP_SHARED file of the same layout) and keeps each thread's cmux_trace_writer in thread-local
 * storage; cmux_trace_test.c refuses to compile the header if it names an allocator, a mapping or a
 * lock. A write is the category load, the clock read and the record's stores; once per 31 records
 * it claims a chunk with one fetch_add and one compare-exchange.
 *
 * It compiles as C11 (stdatomic) and, for the Objective-C++ shim and host, as C++ with the same
 * GCC/Clang atomic builtins stdatomic lowers to (libc++'s <atomic> refuses <stdatomic.h> before
 * C++23). Linux callers need POSIX visible (_GNU_SOURCE or gnu11) for the clock and thread name.
 * Little-endian targets only (arm64, x86-64), as the format. */
#ifndef CMUX_TRACE_H
#define CMUX_TRACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#if defined(__APPLE__) || defined(__linux__)
#include <pthread.h>
#endif
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
#if defined(__linux__) && defined(_GNU_SOURCE)
#include <unistd.h>
#endif

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "ring v1 is little-endian; cmux_trace.h supports little-endian targets only"
#endif

/* ---- Atomics: stdatomic in C, the same builtins in C++. -------------------------------------- */

#if defined(__cplusplus)
#define CMUX_TRACE__STATIC_ASSERT(cond, why) static_assert(cond, why)
typedef int cmux_trace__order;
#define CMUX_TRACE__RELAXED __ATOMIC_RELAXED
#define CMUX_TRACE__ACQUIRE __ATOMIC_ACQUIRE
#define CMUX_TRACE__RELEASE __ATOMIC_RELEASE
#define CMUX_TRACE__ACQ_REL __ATOMIC_ACQ_REL
static inline uint32_t cmux_trace__ld32(void *at, cmux_trace__order order) {
  return __atomic_load_n((uint32_t *)at, order);
}
static inline uint64_t cmux_trace__ld64(void *at, cmux_trace__order order) {
  return __atomic_load_n((uint64_t *)at, order);
}
static inline void cmux_trace__st32(void *at, uint32_t value, cmux_trace__order order) {
  __atomic_store_n((uint32_t *)at, value, order);
}
static inline void cmux_trace__st64(void *at, uint64_t value, cmux_trace__order order) {
  __atomic_store_n((uint64_t *)at, value, order);
}
static inline uint32_t cmux_trace__add32(void *at, uint32_t value, cmux_trace__order order) {
  return __atomic_fetch_add((uint32_t *)at, value, order);
}
static inline uint64_t cmux_trace__add64(void *at, uint64_t value, cmux_trace__order order) {
  return __atomic_fetch_add((uint64_t *)at, value, order);
}
static inline bool cmux_trace__cas32(void *at, uint32_t *expected, uint32_t desired,
                                     cmux_trace__order success, cmux_trace__order failure) {
  return __atomic_compare_exchange_n((uint32_t *)at, expected, desired, false, success, failure);
}
static inline bool cmux_trace__cas64(void *at, uint64_t *expected, uint64_t desired,
                                     cmux_trace__order success, cmux_trace__order failure) {
  return __atomic_compare_exchange_n((uint64_t *)at, expected, desired, false, success, failure);
}
static inline void cmux_trace__fence(cmux_trace__order order) { __atomic_thread_fence(order); }
#else
#include <stdatomic.h>
#define CMUX_TRACE__STATIC_ASSERT(cond, why) _Static_assert(cond, why)
typedef memory_order cmux_trace__order;
#define CMUX_TRACE__RELAXED memory_order_relaxed
#define CMUX_TRACE__ACQUIRE memory_order_acquire
#define CMUX_TRACE__RELEASE memory_order_release
#define CMUX_TRACE__ACQ_REL memory_order_acq_rel
CMUX_TRACE__STATIC_ASSERT(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
                          "ring words are lock-free atomics in shared memory");
CMUX_TRACE__STATIC_ASSERT(sizeof(_Atomic(uint64_t)) == 8 && sizeof(_Atomic(uint32_t)) == 4,
                          "an atomic word has the size of the plain word it overlays");
static inline uint32_t cmux_trace__ld32(void *at, cmux_trace__order order) {
  return atomic_load_explicit((_Atomic(uint32_t) *)at, order);
}
static inline uint64_t cmux_trace__ld64(void *at, cmux_trace__order order) {
  return atomic_load_explicit((_Atomic(uint64_t) *)at, order);
}
static inline void cmux_trace__st32(void *at, uint32_t value, cmux_trace__order order) {
  atomic_store_explicit((_Atomic(uint32_t) *)at, value, order);
}
static inline void cmux_trace__st64(void *at, uint64_t value, cmux_trace__order order) {
  atomic_store_explicit((_Atomic(uint64_t) *)at, value, order);
}
static inline uint32_t cmux_trace__add32(void *at, uint32_t value, cmux_trace__order order) {
  return atomic_fetch_add_explicit((_Atomic(uint32_t) *)at, value, order);
}
static inline uint64_t cmux_trace__add64(void *at, uint64_t value, cmux_trace__order order) {
  return atomic_fetch_add_explicit((_Atomic(uint64_t) *)at, value, order);
}
static inline bool cmux_trace__cas32(void *at, uint32_t *expected, uint32_t desired,
                                     cmux_trace__order success, cmux_trace__order failure) {
  return atomic_compare_exchange_strong_explicit((_Atomic(uint32_t) *)at, expected, desired, success,
                                                 failure);
}
static inline bool cmux_trace__cas64(void *at, uint64_t *expected, uint64_t desired,
                                     cmux_trace__order success, cmux_trace__order failure) {
  return atomic_compare_exchange_strong_explicit((_Atomic(uint64_t) *)at, expected, desired, success,
                                                 failure);
}
static inline void cmux_trace__fence(cmux_trace__order order) { atomic_thread_fence(order); }
#endif

/* ---- The format's numbers (trace.md tables; layout.rs and TraceRuntime pin the same). -------- */

#define CMUX_TRACE_MAGIC "CMXTRACE"
#define CMUX_TRACE_VERSION 1u
#define CMUX_TRACE_HEADER_BYTES 256u
#define CMUX_TRACE_PAGE_BYTES 16384u
#define CMUX_TRACE_NAME_ENTRY_BYTES 64u
#define CMUX_TRACE_NAME_TEXT_BYTES 55u
#define CMUX_TRACE_THREAD_ENTRY_BYTES 64u
#define CMUX_TRACE_THREAD_NAME_BYTES 46u
#define CMUX_TRACE_CHUNK_BYTES 1024u
#define CMUX_TRACE_RECORD_BYTES 32u
#define CMUX_TRACE_RECORDS_PER_CHUNK 31u
#define CMUX_TRACE_CLAIM_TRIES 4u
#define CMUX_TRACE_THREAD_NONE 0xFFFFFFFFu
#define CMUX_TRACE_MAX_NAME_CAPACITY 65536u
#define CMUX_TRACE_MAX_THREAD_CAPACITY 65536u
#define CMUX_TRACE_THREAD_CAPACITY_STEP (CMUX_TRACE_PAGE_BYTES / CMUX_TRACE_THREAD_ENTRY_BYTES)
#define CMUX_TRACE_MAX_CHUNKS (1u << 20)

/* Header offsets. */
#define CMUX_TRACE_OFF_MAGIC 0u
#define CMUX_TRACE_OFF_VERSION 8u
#define CMUX_TRACE_OFF_HEADER_BYTES 12u
#define CMUX_TRACE_OFF_PID 16u
#define CMUX_TRACE_OFF_ROLE_KIND_CLOCK 20u /* role u16 at 20, ring_kind u8 at 22, clock_domain u8 at 23 */
#define CMUX_TRACE_OFF_START_UPTIME_NS 24u
#define CMUX_TRACE_OFF_START_UNIX_NS 32u
#define CMUX_TRACE_OFF_PROCESS_START_UNIX_US 40u
#define CMUX_TRACE_OFF_BOOT_SESSION_UUID 48u
#define CMUX_TRACE_OFF_BUILD_UUID 64u
#define CMUX_TRACE_OFF_BUILD_VERSION 80u
#define CMUX_TRACE_OFF_CHUNK_BYTES 112u
#define CMUX_TRACE_OFF_CHUNK_COUNT 116u
#define CMUX_TRACE_OFF_CHUNKS_OFFSET 120u
#define CMUX_TRACE_OFF_CHUNK_CURSOR 128u
#define CMUX_TRACE_OFF_NAME_TABLE_OFFSET 136u
#define CMUX_TRACE_OFF_NAME_CAPACITY 144u
#define CMUX_TRACE_OFF_NAME_CURSOR 148u
#define CMUX_TRACE_OFF_THREAD_TABLE_OFFSET 152u
#define CMUX_TRACE_OFF_THREAD_CAPACITY 160u
#define CMUX_TRACE_OFF_THREAD_CURSOR 164u
#define CMUX_TRACE_OFF_CATEGORIES 168u
#define CMUX_TRACE_OFF_CHUNKS_SKIPPED 176u
#define CMUX_TRACE_OFF_RECORDS_DROPPED 184u
#define CMUX_TRACE_OFF_NAME_OVERFLOW 192u
#define CMUX_TRACE_OFF_THREAD_OVERFLOW 196u
#define CMUX_TRACE_OFF_HEAP_CURSOR 200u
#define CMUX_TRACE_OFF_START_CONTINUOUS_NS 208u
#define CMUX_TRACE_OFF_CHUNKS_OVERWRITTEN 216u
#define CMUX_TRACE_OFF_RECORDING_START_CURSOR 224u
#define CMUX_TRACE_OFF_HEAP_CHUNKS_LOST 232u
/* Name entry: state u32 at 0; id u16 at 4, kind u8 at 6, category u8 at 7; name_len u8 at 8, text at 9. */
#define CMUX_TRACE_OFF_N_STATE 0u
#define CMUX_TRACE_OFF_N_META 4u
#define CMUX_TRACE_OFF_N_TEXT 8u
/* Thread entry: state u32, generation u32, tid u64; qos u8 at 16, name_len u8 at 17, name at 18. */
#define CMUX_TRACE_OFF_T_STATE 0u
#define CMUX_TRACE_OFF_T_GENERATION 4u
#define CMUX_TRACE_OFF_T_TID 8u
#define CMUX_TRACE_OFF_T_INFO 16u
/* Chunk header. */
#define CMUX_TRACE_OFF_C_THREAD 0u
#define CMUX_TRACE_OFF_C_GENERATION 4u
#define CMUX_TRACE_OFF_C_LAP_SEQ 8u
#define CMUX_TRACE_OFF_C_PUBLISHED 16u
/* Record: t_ns u64; seq u32 at 8; name u16 at 12, phase u8 at 14, flags u8 at 15; arg0; arg1. */
#define CMUX_TRACE_OFF_R_T_NS 0u
#define CMUX_TRACE_OFF_R_SEQ 8u
#define CMUX_TRACE_OFF_R_META 12u
#define CMUX_TRACE_OFF_R_ARG0 16u
#define CMUX_TRACE_OFF_R_ARG1 24u

/* Name and thread entry states. */
#define CMUX_TRACE_ENTRY_WRITING 1u
#define CMUX_TRACE_ENTRY_PUBLISHED 2u
#define CMUX_TRACE_THREAD_LIVE 2u
#define CMUX_TRACE_THREAD_EXITED 3u

/* Header `role` (u16 at 20). */
#define CMUX_TRACE_ROLE_APP 1u
#define CMUX_TRACE_ROLE_DAEMON 2u
#define CMUX_TRACE_ROLE_HOLDER 3u
#define CMUX_TRACE_ROLE_TERMINAL_HOST 4u
#define CMUX_TRACE_ROLE_ACPMUX 5u
#define CMUX_TRACE_ROLE_CHROMIUM_HOST 6u
#define CMUX_TRACE_ROLE_CLI 7u

/* Header `ring_kind` (u8 at 22). */
#define CMUX_TRACE_RING_BLACK_BOX 1u
#define CMUX_TRACE_RING_RECORDING 2u

/* Header `clock_domain` (u8 at 23). */
#define CMUX_TRACE_CLOCK_UPTIME_RAW 1u
#define CMUX_TRACE_CLOCK_MONOTONIC 2u
#define CMUX_TRACE_CLOCK_QPC 3u

/* Name entry `kind` (u8 at 6). */
#define CMUX_TRACE_NAME_CATALOG 1u
#define CMUX_TRACE_NAME_INTERNED 2u
#define CMUX_TRACE_NAME_CATEGORY 3u

/* Record `phase` (u8 at 14): Chrome's TRACE_EVENT_PHASE_* (base/trace_event/common/trace_event_common.h). */
#define CMUX_TRACE_PHASE_BEGIN 0x42u       /* 'B' */
#define CMUX_TRACE_PHASE_END 0x45u         /* 'E' */
#define CMUX_TRACE_PHASE_INSTANT 0x49u     /* 'I' */
#define CMUX_TRACE_PHASE_ASYNC_BEGIN 0x62u /* 'b': arg1 is the async id, with CMUX_TRACE_FLAG_ID */
#define CMUX_TRACE_PHASE_ASYNC_END 0x65u   /* 'e' */
#define CMUX_TRACE_PHASE_FLOW_OUT 0x73u    /* 's': arg1 is the flow id */
#define CMUX_TRACE_PHASE_FLOW_IN 0x66u     /* 'f' */
#define CMUX_TRACE_PHASE_COUNTER 0x43u     /* 'C': arg0 the value, arg1 a track id */

/* Record `flags` (u8 at 15). */
#define CMUX_TRACE_FLAG_ID 0x01u       /* arg1 is an async or track id */
#define CMUX_TRACE_FLAG_ESTIMATE 0x02u /* t_ns is an estimate */

/* Category bits (trace.md "Release trace ring: category bits"). */
#define CMUX_TRACE_CAT_ACTION (UINT64_C(1) << 0)
#define CMUX_TRACE_CAT_KEY (UINT64_C(1) << 1)
#define CMUX_TRACE_CAT_SWITCH (UINT64_C(1) << 2)
#define CMUX_TRACE_CAT_CREATE (UINT64_C(1) << 3)
#define CMUX_TRACE_CAT_CEF (UINT64_C(1) << 4)
#define CMUX_TRACE_CAT_LAUNCH (UINT64_C(1) << 5)
#define CMUX_TRACE_CAT_DAEMON (UINT64_C(1) << 6)
#define CMUX_TRACE_CAT_HANG (UINT64_C(1) << 7)
#define CMUX_TRACE_CAT_CRASH (UINT64_C(1) << 8)
#define CMUX_TRACE_CAT_MOTION (UINT64_C(1) << 9)
#define CMUX_TRACE_CAT_FRAME (UINT64_C(1) << 10)
#define CMUX_TRACE_CAT_STALL (UINT64_C(1) << 11)
#define CMUX_TRACE_CAT_TASK (UINT64_C(1) << 12)
#define CMUX_TRACE_CAT_BURST (UINT64_C(1) << 13)
#define CMUX_TRACE_CAT_INPUT (UINT64_C(1) << 14)
#define CMUX_TRACE_CAT_WEBVIEW (UINT64_C(1) << 15)
#define CMUX_TRACE_CAT_REMOTE (UINT64_C(1) << 16)
#define CMUX_TRACE_CAT_CONTROL (UINT64_C(1) << 17)
#define CMUX_TRACE_CAT_GHOSTTY (UINT64_C(1) << 18)
#define CMUX_TRACE_CAT_RESIZE (UINT64_C(1) << 19)
#define CMUX_TRACE_CAT_BLACKBOX UINT64_C(0x1ff) /* bits 0-8: on from launch */
#define CMUX_TRACE_CAT_RECORDING UINT64_C(0xffe00) /* bits 9-19: a recording adds them */
#define CMUX_TRACE_CAT_ALL (CMUX_TRACE_CAT_BLACKBOX | CMUX_TRACE_CAT_RECORDING)

/* Errors of the control calls. */
typedef enum cmux_trace_error {
  CMUX_TRACE_OK = 0,
  CMUX_TRACE_ERROR_ALREADY_RECORDING = 1, /* a recording runs, or a start or stop is changing state */
  CMUX_TRACE_ERROR_NOT_RECORDING = 2,
  CMUX_TRACE_ERROR_NO_RECORDING_RING = 3, /* cmux_trace_tracer_attach_recording has not run */
  CMUX_TRACE_ERROR_ALREADY_ATTACHED = 4,  /* the black box has its file, or the recording its ring */
  CMUX_TRACE_ERROR_LAYOUT_MISMATCH = 5,   /* a file ring's layout differs from the heap ring's */
} cmux_trace_error;

/* ---- Layout. ------------------------------------------------------------------------------- */

typedef struct cmux_trace_sizes {
  uint32_t name_capacity;
  uint32_t thread_capacity;
  uint32_t chunk_count;
} cmux_trace_sizes;

typedef struct cmux_trace_layout {
  cmux_trace_sizes sizes;
  size_t name_table_offset;
  size_t thread_table_offset;
  size_t chunks_offset;
  size_t total_bytes;
} cmux_trace_layout;

static inline uint32_t cmux_trace__clamp32(uint32_t value, uint32_t low, uint32_t high) {
  return value < low ? low : (value > high ? high : value);
}

static inline size_t cmux_trace__round_up(size_t value, size_t step) {
  return (value + step - 1) / step * step;
}

/* The sizes the format allows nearest to `sizes`: a power-of-two chunk count, whole 16 KiB pages of
 * thread entries and at most 65536 names. */
static inline cmux_trace_sizes cmux_trace_sizes_normalized(cmux_trace_sizes sizes) {
  cmux_trace_sizes out;
  uint32_t chunks = cmux_trace__clamp32(sizes.chunk_count, 1, CMUX_TRACE_MAX_CHUNKS);
  uint32_t power = 1;
  while (power < chunks) power <<= 1;
  out.name_capacity = cmux_trace__clamp32(sizes.name_capacity, 1, CMUX_TRACE_MAX_NAME_CAPACITY);
  out.thread_capacity = (uint32_t)cmux_trace__round_up(
      cmux_trace__clamp32(sizes.thread_capacity, 1, CMUX_TRACE_MAX_THREAD_CAPACITY),
      CMUX_TRACE_THREAD_CAPACITY_STEP);
  out.chunk_count = power;
  return out;
}

/* "Sizes by role". The CLI has no row there and takes the holder's. */
static inline cmux_trace_sizes cmux_trace_role_sizes(uint16_t role, uint8_t ring_kind) {
  cmux_trace_sizes sizes;
  uint32_t blackbox, recording;
  switch (role) {
    case CMUX_TRACE_ROLE_APP:
    case CMUX_TRACE_ROLE_DAEMON:
      sizes.name_capacity = 4096, sizes.thread_capacity = 2048, blackbox = 512, recording = 32768;
      break;
    case CMUX_TRACE_ROLE_CHROMIUM_HOST:
      sizes.name_capacity = 4096, sizes.thread_capacity = 2048, blackbox = 512, recording = 8192;
      break;
    case CMUX_TRACE_ROLE_TERMINAL_HOST:
      sizes.name_capacity = 1024, sizes.thread_capacity = 256, blackbox = 64, recording = 512;
      break;
    default: /* holder, acpmux, CLI */
      sizes.name_capacity = 2048, sizes.thread_capacity = 512, blackbox = 256, recording = 8192;
      break;
  }
  sizes.chunk_count = ring_kind == CMUX_TRACE_RING_RECORDING ? recording : blackbox;
  return sizes;
}

/* Where each region sits: the header page, the name table, the thread table, then the chunks, each
 * on a 16 KiB page (the header names each offset, so a decoder computes none). */
static inline cmux_trace_layout cmux_trace_layout_of(cmux_trace_sizes requested) {
  cmux_trace_layout layout;
  cmux_trace_sizes sizes = cmux_trace_sizes_normalized(requested);
  layout.sizes = sizes;
  layout.name_table_offset = CMUX_TRACE_PAGE_BYTES;
  layout.thread_table_offset =
      layout.name_table_offset +
      cmux_trace__round_up((size_t)sizes.name_capacity * CMUX_TRACE_NAME_ENTRY_BYTES, CMUX_TRACE_PAGE_BYTES);
  layout.chunks_offset =
      layout.thread_table_offset + cmux_trace__round_up((size_t)sizes.thread_capacity * CMUX_TRACE_THREAD_ENTRY_BYTES,
                                                        CMUX_TRACE_PAGE_BYTES);
  layout.total_bytes = layout.chunks_offset + (size_t)sizes.chunk_count * CMUX_TRACE_CHUNK_BYTES;
  return layout;
}

static inline bool cmux_trace_layout_equal(const cmux_trace_layout *a, const cmux_trace_layout *b) {
  return a->sizes.name_capacity == b->sizes.name_capacity && a->sizes.thread_capacity == b->sizes.thread_capacity &&
         a->sizes.chunk_count == b->sizes.chunk_count && a->total_bytes == b->total_bytes;
}

/* `lap_seq` of a chunk of `lap`: owned and filling, complete; the lap a nonzero `lap_seq` names. */
static inline uint64_t cmux_trace_lap_owned(uint64_t lap) { return 2 * lap + 1; }
static inline uint64_t cmux_trace_lap_complete(uint64_t lap) { return 2 * lap + 2; }
static inline uint64_t cmux_trace_lap_of(uint64_t lap_seq) { return (lap_seq - 1) / 2; }

/* ---- Clock (trace.md "Clock"). ------------------------------------------------------------- */

#if defined(__APPLE__)
#define CMUX_TRACE_HAS_CLOCK 1
#define CMUX_TRACE_CLOCK_DOMAIN_CURRENT CMUX_TRACE_CLOCK_UPTIME_RAW
/* CLOCK_UPTIME_RAW: mach_absolute_time's clock, Chromium's TimeTicks (base/time/time_mac.mm). A commpage read. */
static inline uint64_t cmux_trace_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
/* mach_continuous_time, which counts sleep: the header's start_continuous_ns. */
static inline uint64_t cmux_trace_continuous_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }
#elif defined(__linux__) && defined(CLOCK_MONOTONIC)
#define CMUX_TRACE_HAS_CLOCK 1
#define CMUX_TRACE_CLOCK_DOMAIN_CURRENT CMUX_TRACE_CLOCK_MONOTONIC
static inline uint64_t cmux_trace__timespec_ns(clockid_t clock) {
  struct timespec now = {0, 0};
  clock_gettime(clock, &now);
  return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}
/* CLOCK_MONOTONIC: a vDSO read. */
static inline uint64_t cmux_trace_now_ns(void) { return cmux_trace__timespec_ns(CLOCK_MONOTONIC); }
static inline uint64_t cmux_trace_continuous_ns(void) {
#if defined(CLOCK_BOOTTIME)
  return cmux_trace__timespec_ns(CLOCK_BOOTTIME);
#else
  return 0;
#endif
}
#endif

#if defined(CMUX_TRACE_HAS_CLOCK)
/* The wall clock: the header's start_unix_ns (display and cleanup only, never a record time). */
static inline uint64_t cmux_trace_unix_ns(void) {
  struct timespec now = {0, 0};
  clock_gettime(CLOCK_REALTIME, &now);
  return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}
#endif

/* ---- Records, names and threads. ----------------------------------------------------------- */

typedef struct cmux_trace_record {
  uint64_t t_ns;
  uint16_t name;
  uint8_t phase;
  uint8_t flags;
  uint64_t arg0;
  uint64_t arg1;
} cmux_trace_record;

/* One fixed name the ring's creator writes before the ring is active, so its id is the same in
 * every ring of the process. */
typedef struct cmux_trace_catalog_name {
  uint16_t id;      /* the entry index, from 1 */
  uint8_t kind;     /* CMUX_TRACE_NAME_CATALOG or CMUX_TRACE_NAME_CATEGORY */
  uint8_t category; /* the category's bit index */
  const char *text; /* UTF-8, cut at 55 bytes on a character boundary */
} cmux_trace_catalog_name;

/* A trace point named at run time: a static at its site, with its id in each of the process's three
 * rings (bits 16 * slot of `ids`, 0 until interned there). Read and written only atomically. */
typedef struct cmux_trace_interned_name {
  const char *text;
  uint8_t category;
  uint64_t ids;
} cmux_trace_interned_name;

/* A thread as its thread entry records it. */
typedef struct cmux_trace_thread_identity {
  uint64_t tid;
  uint8_t qos;
  uint8_t name_len;
  uint8_t name[CMUX_TRACE_THREAD_NAME_BYTES];
} cmux_trace_thread_identity;

/* The length of the longest prefix of `text` of at most `max` bytes that ends on a UTF-8 character
 * boundary. */
static inline size_t cmux_trace__utf8_prefix(const char *text, size_t max) {
  size_t end = 0;
  if (!text) return 0;
  while (end <= max && text[end] != '\0') end++;
  if (end <= max) return end;
  end = max;
  while (end > 0 && ((unsigned char)text[end] & 0xC0u) == 0x80u) end--;
  return end;
}

static inline cmux_trace_thread_identity cmux_trace_thread_identity_make(uint64_t tid, uint8_t qos,
                                                                         const char *name) {
  cmux_trace_thread_identity identity;
  size_t length = cmux_trace__utf8_prefix(name, CMUX_TRACE_THREAD_NAME_BYTES);
  size_t index;
  identity.tid = tid;
  identity.qos = qos;
  identity.name_len = (uint8_t)length;
  for (index = 0; index < CMUX_TRACE_THREAD_NAME_BYTES; index++) {
    identity.name[index] = index < length ? (uint8_t)name[index] : 0;
  }
  return identity;
}

#if defined(__APPLE__) || (defined(__linux__) && defined(_GNU_SOURCE))
#define CMUX_TRACE_HAS_CURRENT_THREAD 1
/* The calling thread: its tid, QoS and name, read once at its first record (no allocation). */
static inline cmux_trace_thread_identity cmux_trace_thread_identity_current(void) {
  char name[64] = {0};
  uint64_t tid = 0;
  uint8_t qos = 0;
#if defined(__APPLE__)
  qos_class_t qos_class = QOS_CLASS_UNSPECIFIED;
  int relative = 0;
  pthread_threadid_np(NULL, &tid);
  pthread_get_qos_class_np(pthread_self(), &qos_class, &relative);
  qos = (uint8_t)(uint32_t)qos_class;
#else
  tid = (uint64_t)gettid();
#endif
  if (pthread_getname_np(pthread_self(), name, sizeof name) != 0) name[0] = '\0';
  name[sizeof name - 1] = '\0';
  return cmux_trace_thread_identity_make(tid, qos, name);
}
#endif

/* ---- One ring: header, tables and chunks, and the writer's operations on them ("Writing"). --- */

typedef struct cmux_trace_ring {
  uint8_t *base; /* layout.total_bytes, 8-byte aligned, zeroed before init; never freed while a writer can reach it */
  cmux_trace_layout layout;
} cmux_trace_ring;

/* The header fields a ring's creator writes; the cursors, offsets and counters follow from the layout. */
typedef struct cmux_trace_header_fields {
  uint32_t pid;
  uint16_t role;
  uint8_t ring_kind;
  uint8_t clock_domain;
  uint64_t start_uptime_ns;
  uint64_t start_unix_ns;
  uint64_t start_continuous_ns;
  uint64_t process_start_unix_us;
  uint8_t boot_session_uuid[16];
  uint8_t build_uuid[16];
  uint8_t build_version[32];
  uint64_t categories;
} cmux_trace_header_fields;

static inline cmux_trace_ring cmux_trace_ring_on(void *zeroed, cmux_trace_layout layout) {
  cmux_trace_ring ring;
  ring.base = (uint8_t *)zeroed;
  ring.layout = layout;
  return ring;
}

static inline void *cmux_trace__at(const cmux_trace_ring *ring, size_t offset) { return ring->base + offset; }
static inline size_t cmux_trace__name_entry(const cmux_trace_ring *ring, size_t index) {
  return ring->layout.name_table_offset + index * CMUX_TRACE_NAME_ENTRY_BYTES;
}
static inline size_t cmux_trace__thread_entry(const cmux_trace_ring *ring, size_t index) {
  return ring->layout.thread_table_offset + index * CMUX_TRACE_THREAD_ENTRY_BYTES;
}
static inline size_t cmux_trace__chunk(const cmux_trace_ring *ring, size_t index) {
  return ring->layout.chunks_offset + index * CMUX_TRACE_CHUNK_BYTES;
}

static inline uint32_t cmux_trace__ld32_at(const cmux_trace_ring *ring, size_t offset, cmux_trace__order order) {
  return cmux_trace__ld32(cmux_trace__at(ring, offset), order);
}
static inline uint64_t cmux_trace__ld64_at(const cmux_trace_ring *ring, size_t offset, cmux_trace__order order) {
  return cmux_trace__ld64(cmux_trace__at(ring, offset), order);
}
static inline void cmux_trace__st32_at(const cmux_trace_ring *ring, size_t offset, uint32_t value,
                                       cmux_trace__order order) {
  cmux_trace__st32(cmux_trace__at(ring, offset), value, order);
}
static inline void cmux_trace__st64_at(const cmux_trace_ring *ring, size_t offset, uint64_t value,
                                       cmux_trace__order order) {
  cmux_trace__st64(cmux_trace__at(ring, offset), value, order);
}
static inline void cmux_trace__bump32(const cmux_trace_ring *ring, size_t offset) {
  cmux_trace__add32(cmux_trace__at(ring, offset), 1, CMUX_TRACE__RELAXED);
}
static inline void cmux_trace__bump64(const cmux_trace_ring *ring, size_t offset) {
  cmux_trace__add64(cmux_trace__at(ring, offset), 1, CMUX_TRACE__RELAXED);
}

/* Stores `count` bytes (a multiple of 8) as relaxed little-endian u64 words. */
static inline void cmux_trace__put_bytes(const cmux_trace_ring *ring, size_t offset, const uint8_t *bytes,
                                         size_t count) {
  size_t word, index;
  for (word = 0; word < count / 8; word++) {
    uint64_t value = 0;
    for (index = 0; index < 8; index++) value |= (uint64_t)bytes[8 * word + index] << (8 * index);
    cmux_trace__st64_at(ring, offset + 8 * word, value, CMUX_TRACE__RELAXED);
  }
}

static inline void cmux_trace__write_name(const cmux_trace_ring *ring, uint16_t id, uint8_t kind, uint8_t category,
                                          const char *text) {
  size_t at = cmux_trace__name_entry(ring, id);
  size_t length = cmux_trace__utf8_prefix(text, CMUX_TRACE_NAME_TEXT_BYTES), index;
  uint8_t packed[1 + CMUX_TRACE_NAME_TEXT_BYTES];
  cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_N_STATE, CMUX_TRACE_ENTRY_WRITING, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_N_META,
                      (uint32_t)id | (uint32_t)kind << 16 | (uint32_t)category << 24, CMUX_TRACE__RELAXED);
  packed[0] = (uint8_t)length;
  for (index = 0; index < CMUX_TRACE_NAME_TEXT_BYTES; index++) {
    packed[1 + index] = index < length ? (uint8_t)text[index] : 0;
  }
  cmux_trace__put_bytes(ring, at + CMUX_TRACE_OFF_N_TEXT, packed, sizeof packed);
  cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_N_STATE, CMUX_TRACE_ENTRY_PUBLISHED, CMUX_TRACE__RELEASE);
}

static inline void cmux_trace_ring_put_start_times(const cmux_trace_ring *ring, uint64_t uptime_ns, uint64_t unix_ns,
                                                   uint64_t continuous_ns) {
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_START_UPTIME_NS, uptime_ns, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_START_UNIX_NS, unix_ns, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_START_CONTINUOUS_NS, continuous_ns, CMUX_TRACE__RELAXED);
}

/* The identity fields read off the hot path (a sysctl or a file): written when the ring file is made. */
static inline void cmux_trace_ring_put_slow_identity(const cmux_trace_ring *ring, uint64_t process_start_unix_us,
                                                     const uint8_t boot_session_uuid[16]) {
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_PROCESS_START_UNIX_US, process_start_unix_us, CMUX_TRACE__RELAXED);
  cmux_trace__put_bytes(ring, CMUX_TRACE_OFF_BOOT_SESSION_UUID, boot_session_uuid, 16);
}

static inline void cmux_trace_ring_set_categories(const cmux_trace_ring *ring, uint64_t categories) {
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_CATEGORIES, categories, CMUX_TRACE__RELAXED);
}

/* Writes the header and the catalog while the ring is still private (before any writer can reach
 * it). `name_cursor` becomes the last catalog id + 1, at least 1; an id outside the table is
 * counted in `name_overflow`. */
static inline void cmux_trace_ring_init(const cmux_trace_ring *ring, const cmux_trace_header_fields *fields,
                                        const cmux_trace_catalog_name *catalog, size_t catalog_count) {
  const cmux_trace_sizes sizes = ring->layout.sizes;
  const uint8_t magic[8] = {'C', 'M', 'X', 'T', 'R', 'A', 'C', 'E'};
  uint32_t cursor = 1;
  size_t index;
  cmux_trace__put_bytes(ring, CMUX_TRACE_OFF_MAGIC, magic, 8);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_VERSION, CMUX_TRACE_VERSION, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_HEADER_BYTES, CMUX_TRACE_HEADER_BYTES, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_PID, fields->pid, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_ROLE_KIND_CLOCK,
                      (uint32_t)fields->role | (uint32_t)fields->ring_kind << 16 |
                          (uint32_t)fields->clock_domain << 24,
                      CMUX_TRACE__RELAXED);
  cmux_trace_ring_put_start_times(ring, fields->start_uptime_ns, fields->start_unix_ns, fields->start_continuous_ns);
  cmux_trace_ring_put_slow_identity(ring, fields->process_start_unix_us, fields->boot_session_uuid);
  cmux_trace__put_bytes(ring, CMUX_TRACE_OFF_BUILD_UUID, fields->build_uuid, 16);
  cmux_trace__put_bytes(ring, CMUX_TRACE_OFF_BUILD_VERSION, fields->build_version, 32);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_CHUNK_BYTES, CMUX_TRACE_CHUNK_BYTES, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_CHUNK_COUNT, sizes.chunk_count, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_CHUNKS_OFFSET, ring->layout.chunks_offset, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_NAME_TABLE_OFFSET, ring->layout.name_table_offset, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_NAME_CAPACITY, sizes.name_capacity, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_THREAD_TABLE_OFFSET, ring->layout.thread_table_offset,
                      CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_THREAD_CAPACITY, sizes.thread_capacity, CMUX_TRACE__RELAXED);
  cmux_trace_ring_set_categories(ring, fields->categories);
  for (index = 0; index < catalog_count; index++) {
    const cmux_trace_catalog_name *name = &catalog[index];
    if (name->id == 0 || (uint32_t)name->id >= sizes.name_capacity) {
      cmux_trace__bump32(ring, CMUX_TRACE_OFF_NAME_OVERFLOW);
      continue;
    }
    cmux_trace__write_name(ring, name->id, name->kind, name->category, name->text);
    if ((uint32_t)name->id + 1 > cursor) cursor = (uint32_t)name->id + 1;
  }
  cmux_trace__st32_at(ring, CMUX_TRACE_OFF_NAME_CURSOR, cursor, CMUX_TRACE__RELAXED);
}

/* Claims a name entry for `text` and publishes it; its id, or 0 (counted in `name_overflow`) when
 * the table is full. */
static inline uint16_t cmux_trace_ring_intern(const cmux_trace_ring *ring, const char *text, uint8_t category) {
  uint32_t capacity = ring->layout.sizes.name_capacity;
  void *cursor = cmux_trace__at(ring, CMUX_TRACE_OFF_NAME_CURSOR);
  uint32_t id = cmux_trace__ld32(cursor, CMUX_TRACE__RELAXED) < capacity
                    ? cmux_trace__add32(cursor, 1, CMUX_TRACE__RELAXED)
                    : capacity;
  if (id >= capacity) {
    cmux_trace__bump32(ring, CMUX_TRACE_OFF_NAME_OVERFLOW);
    return 0;
  }
  cmux_trace__write_name(ring, (uint16_t)id, CMUX_TRACE_NAME_INTERNED, category, text);
  return (uint16_t)id;
}

static inline void cmux_trace__fill_thread(const cmux_trace_ring *ring, size_t at,
                                           const cmux_trace_thread_identity *identity) {
  uint8_t info[48];
  size_t index;
  info[0] = identity->qos;
  info[1] = identity->name_len;
  for (index = 0; index < CMUX_TRACE_THREAD_NAME_BYTES; index++) info[2 + index] = identity->name[index];
  cmux_trace__st64_at(ring, at + CMUX_TRACE_OFF_T_TID, identity->tid, CMUX_TRACE__RELAXED);
  cmux_trace__put_bytes(ring, at + CMUX_TRACE_OFF_T_INFO, info, sizeof info);
  cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_T_STATE, CMUX_TRACE_THREAD_LIVE, CMUX_TRACE__RELEASE);
}

/* "Register a thread in a ring": a fresh entry in index order, else an exited one taken again with
 * its generation + 1, else CMUX_TRACE_THREAD_NONE and a counted overflow. */
static inline void cmux_trace_ring_register_thread(const cmux_trace_ring *ring,
                                                   const cmux_trace_thread_identity *identity, uint32_t *index_out,
                                                   uint32_t *generation_out) {
  uint32_t capacity = ring->layout.sizes.thread_capacity, index;
  void *cursor = cmux_trace__at(ring, CMUX_TRACE_OFF_THREAD_CURSOR);
  if (cmux_trace__ld32(cursor, CMUX_TRACE__RELAXED) < capacity) {
    index = cmux_trace__add32(cursor, 1, CMUX_TRACE__RELAXED);
    if (index < capacity) {
      size_t at = cmux_trace__thread_entry(ring, index);
      cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_T_STATE, CMUX_TRACE_ENTRY_WRITING, CMUX_TRACE__RELAXED);
      cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_T_GENERATION, 0, CMUX_TRACE__RELAXED);
      cmux_trace__fill_thread(ring, at, identity);
      *index_out = index;
      *generation_out = 0;
      return;
    }
  }
  for (index = 0; index < capacity; index++) {
    size_t at = cmux_trace__thread_entry(ring, index);
    uint32_t expected = CMUX_TRACE_THREAD_EXITED;
    if (cmux_trace__ld32_at(ring, at + CMUX_TRACE_OFF_T_STATE, CMUX_TRACE__RELAXED) == CMUX_TRACE_THREAD_EXITED &&
        cmux_trace__cas32(cmux_trace__at(ring, at + CMUX_TRACE_OFF_T_STATE), &expected, CMUX_TRACE_ENTRY_WRITING,
                          CMUX_TRACE__ACQUIRE, CMUX_TRACE__RELAXED)) {
      uint32_t generation =
          cmux_trace__ld32_at(ring, at + CMUX_TRACE_OFF_T_GENERATION, CMUX_TRACE__RELAXED) + 1;
      cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_T_GENERATION, generation, CMUX_TRACE__RELAXED);
      cmux_trace__fill_thread(ring, at, identity);
      *index_out = index;
      *generation_out = generation;
      return;
    }
  }
  cmux_trace__bump32(ring, CMUX_TRACE_OFF_THREAD_OVERFLOW);
  *index_out = CMUX_TRACE_THREAD_NONE;
  *generation_out = 0;
}

/* Marks entry `index` exited (the thread's exit), so a later thread may take it. */
static inline void cmux_trace_ring_exit_thread(const cmux_trace_ring *ring, uint32_t index) {
  if (index < ring->layout.sizes.thread_capacity) {
    cmux_trace__st32_at(ring, cmux_trace__thread_entry(ring, index) + CMUX_TRACE_OFF_T_STATE,
                        CMUX_TRACE_THREAD_EXITED, CMUX_TRACE__RELEASE);
  }
}

/* "Claim a chunk": at most 4 tries; a chunk that is owned (odd `lap_seq`) or claimed by a newer lap
 * is skipped, so two writers never share one. False after counting the dropped record. */
static inline bool cmux_trace_ring_claim(const cmux_trace_ring *ring, uint32_t thread_index,
                                         uint32_t thread_generation, uint32_t *chunk_out, uint64_t *lap_out) {
  const uint64_t count = ring->layout.sizes.chunk_count;
  const uint64_t start_lap =
      cmux_trace__ld64_at(ring, CMUX_TRACE_OFF_RECORDING_START_CURSOR, CMUX_TRACE__ACQUIRE) / count;
  uint32_t tries;
  for (tries = 0; tries < CMUX_TRACE_CLAIM_TRIES; tries++) {
    uint64_t claim = cmux_trace__add64(cmux_trace__at(ring, CMUX_TRACE_OFF_CHUNK_CURSOR), 1, CMUX_TRACE__RELAXED);
    uint32_t chunk = (uint32_t)(claim & (count - 1));
    uint64_t lap = claim / count;
    size_t at = cmux_trace__chunk(ring, chunk);
    void *lap_seq = cmux_trace__at(ring, at + CMUX_TRACE_OFF_C_LAP_SEQ);
    uint64_t seen = cmux_trace__ld64(lap_seq, CMUX_TRACE__RELAXED);
    uint64_t expected = seen;
    if ((seen & 1) == 1 || seen >= cmux_trace_lap_complete(lap) ||
        !cmux_trace__cas64(lap_seq, &expected, cmux_trace_lap_owned(lap), CMUX_TRACE__ACQ_REL,
                           CMUX_TRACE__RELAXED)) {
      cmux_trace__bump64(ring, CMUX_TRACE_OFF_CHUNKS_SKIPPED);
      continue;
    }
    cmux_trace__fence(CMUX_TRACE__RELEASE);
    if (seen >= cmux_trace_lap_complete(start_lap)) cmux_trace__bump64(ring, CMUX_TRACE_OFF_CHUNKS_OVERWRITTEN);
    cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_C_THREAD, thread_index, CMUX_TRACE__RELAXED);
    cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_C_GENERATION, thread_generation, CMUX_TRACE__RELAXED);
    cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_C_PUBLISHED, 0, CMUX_TRACE__RELAXED);
    *chunk_out = chunk;
    *lap_out = lap;
    return true;
  }
  cmux_trace__bump64(ring, CMUX_TRACE_OFF_RECORDS_DROPPED);
  return false;
}

/* "Publish a record" in slot `slot` (1-31) of the owned chunk `chunk` of `lap`. */
static inline void cmux_trace_ring_publish(const cmux_trace_ring *ring, uint32_t chunk, uint64_t lap, uint32_t slot,
                                           const cmux_trace_record *record) {
  size_t chunk_at = cmux_trace__chunk(ring, chunk);
  size_t at = chunk_at + (size_t)slot * CMUX_TRACE_RECORD_BYTES;
  uint32_t writing = (uint32_t)cmux_trace_lap_owned(lap);
  void *seq = cmux_trace__at(ring, at + CMUX_TRACE_OFF_R_SEQ);
  cmux_trace__st32(seq, writing, CMUX_TRACE__RELAXED);
  cmux_trace__fence(CMUX_TRACE__RELEASE);
  cmux_trace__st64_at(ring, at + CMUX_TRACE_OFF_R_T_NS, record->t_ns, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(ring, at + CMUX_TRACE_OFF_R_META,
                      (uint32_t)record->name | (uint32_t)record->phase << 16 | (uint32_t)record->flags << 24,
                      CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, at + CMUX_TRACE_OFF_R_ARG0, record->arg0, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, at + CMUX_TRACE_OFF_R_ARG1, record->arg1, CMUX_TRACE__RELAXED);
  cmux_trace__st32(seq, writing + 1, CMUX_TRACE__RELEASE);
  cmux_trace__st32_at(ring, chunk_at + CMUX_TRACE_OFF_C_PUBLISHED, slot, CMUX_TRACE__RELEASE);
}

/* "Complete the chunk": only its owner stores to an odd `lap_seq`, so this never overwrites another
 * owner's claim. */
static inline void cmux_trace_ring_complete(const cmux_trace_ring *ring, uint32_t chunk, uint64_t lap) {
  cmux_trace__st64_at(ring, cmux_trace__chunk(ring, chunk) + CMUX_TRACE_OFF_C_LAP_SEQ, cmux_trace_lap_complete(lap),
                      CMUX_TRACE__RELEASE);
}

/* "Recording ring", steps 1 and 2 of a trace.start: zero the counters, store the new start times,
 * and move `chunk_cursor` a lap past every claim of an earlier recording. */
static inline void cmux_trace_ring_begin_recording(const cmux_trace_ring *ring, uint64_t uptime_ns, uint64_t unix_ns,
                                                   uint64_t continuous_ns) {
  const uint64_t count = ring->layout.sizes.chunk_count;
  uint64_t claim;
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_CHUNKS_SKIPPED, 0, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_RECORDS_DROPPED, 0, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_CHUNKS_OVERWRITTEN, 0, CMUX_TRACE__RELAXED);
  cmux_trace_ring_put_start_times(ring, uptime_ns, unix_ns, continuous_ns);
  claim = cmux_trace__add64(cmux_trace__at(ring, CMUX_TRACE_OFF_CHUNK_CURSOR), count, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(ring, CMUX_TRACE_OFF_RECORDING_START_CURSOR, claim + count, CMUX_TRACE__RELEASE);
}

/* A header counter (`chunks_skipped`, `records_dropped`, `chunks_overwritten`, `name_overflow`, ...). */
static inline uint64_t cmux_trace_ring_counter(const cmux_trace_ring *ring, size_t offset) {
  if (offset == CMUX_TRACE_OFF_NAME_OVERFLOW || offset == CMUX_TRACE_OFF_THREAD_OVERFLOW ||
      offset == CMUX_TRACE_OFF_HEAP_CHUNKS_LOST || offset == CMUX_TRACE_OFF_NAME_CURSOR ||
      offset == CMUX_TRACE_OFF_THREAD_CURSOR) {
    return cmux_trace__ld32_at(ring, offset, CMUX_TRACE__RELAXED);
  }
  return cmux_trace__ld64_at(ring, offset, CMUX_TRACE__RELAXED);
}

/* ---- Copy with the decode protocol ("Heap, then file" steps 2 and 3; snapshots). ----------- */

/* The header words that hold two u32 fields, copied at the width their writers store them. */
static inline bool cmux_trace__header_u32_pair(size_t at) {
  return at == CMUX_TRACE_OFF_VERSION || at == CMUX_TRACE_OFF_PID || at == CMUX_TRACE_OFF_CHUNK_BYTES ||
         at == CMUX_TRACE_OFF_NAME_CAPACITY || at == CMUX_TRACE_OFF_THREAD_CAPACITY ||
         at == CMUX_TRACE_OFF_NAME_OVERFLOW || at == CMUX_TRACE_OFF_HEAP_CHUNKS_LOST;
}

/* One name or thread entry, kept when its state and second word read the same before and after the
 * copy and the state is published (a thread: live or exited, since copied chunks still name it). */
static inline void cmux_trace__copy_entry(const cmux_trace_ring *src, const cmux_trace_ring *dst, size_t at,
                                          bool thread) {
  uint64_t words[8];
  uint32_t state = cmux_trace__ld32_at(src, at, CMUX_TRACE__ACQUIRE);
  uint32_t second = cmux_trace__ld32_at(src, at + 4, CMUX_TRACE__RELAXED);
  size_t index;
  bool keep = thread ? (state == CMUX_TRACE_THREAD_LIVE || state == CMUX_TRACE_THREAD_EXITED)
                     : state == CMUX_TRACE_ENTRY_PUBLISHED;
  if (!keep) return;
  for (index = 1; index < 8; index++) words[index] = cmux_trace__ld64_at(src, at + 8 * index, CMUX_TRACE__RELAXED);
  cmux_trace__fence(CMUX_TRACE__ACQUIRE);
  if (cmux_trace__ld32_at(src, at, CMUX_TRACE__RELAXED) != state ||
      cmux_trace__ld32_at(src, at + 4, CMUX_TRACE__RELAXED) != second) {
    return;
  }
  for (index = 1; index < 8; index++) cmux_trace__st64_at(dst, at + 8 * index, words[index], CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(dst, at + 4, second, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(dst, at, state, CMUX_TRACE__RELEASE);
}

/* One chunk: a slot whose two `seq` reads differ is left out, a chunk taken over while it was read is
 * left out, and an odd (owned) `lap_seq` is stored complete: the copy has no owner. */
static inline void cmux_trace__copy_chunk(const cmux_trace_ring *src, const cmux_trace_ring *dst, size_t at) {
  uint64_t first = cmux_trace__ld64_at(src, at + CMUX_TRACE_OFF_C_LAP_SEQ, CMUX_TRACE__ACQUIRE), second;
  uint32_t slot, thread, generation, published;
  if (first == 0) return;
  for (slot = 1; slot <= CMUX_TRACE_RECORDS_PER_CHUNK; slot++) {
    size_t record = at + (size_t)slot * CMUX_TRACE_RECORD_BYTES;
    uint32_t seq = cmux_trace__ld32_at(src, record + CMUX_TRACE_OFF_R_SEQ, CMUX_TRACE__ACQUIRE);
    uint64_t t_ns = cmux_trace__ld64_at(src, record + CMUX_TRACE_OFF_R_T_NS, CMUX_TRACE__RELAXED);
    uint32_t meta = cmux_trace__ld32_at(src, record + CMUX_TRACE_OFF_R_META, CMUX_TRACE__RELAXED);
    uint64_t arg0 = cmux_trace__ld64_at(src, record + CMUX_TRACE_OFF_R_ARG0, CMUX_TRACE__RELAXED);
    uint64_t arg1 = cmux_trace__ld64_at(src, record + CMUX_TRACE_OFF_R_ARG1, CMUX_TRACE__RELAXED);
    cmux_trace__fence(CMUX_TRACE__ACQUIRE);
    if (cmux_trace__ld32_at(src, record + CMUX_TRACE_OFF_R_SEQ, CMUX_TRACE__RELAXED) != seq) continue;
    cmux_trace__st64_at(dst, record + CMUX_TRACE_OFF_R_T_NS, t_ns, CMUX_TRACE__RELAXED);
    cmux_trace__st32_at(dst, record + CMUX_TRACE_OFF_R_META, meta, CMUX_TRACE__RELAXED);
    cmux_trace__st64_at(dst, record + CMUX_TRACE_OFF_R_ARG0, arg0, CMUX_TRACE__RELAXED);
    cmux_trace__st64_at(dst, record + CMUX_TRACE_OFF_R_ARG1, arg1, CMUX_TRACE__RELAXED);
    cmux_trace__st32_at(dst, record + CMUX_TRACE_OFF_R_SEQ, seq, CMUX_TRACE__RELAXED);
  }
  cmux_trace__fence(CMUX_TRACE__ACQUIRE);
  thread = cmux_trace__ld32_at(src, at + CMUX_TRACE_OFF_C_THREAD, CMUX_TRACE__RELAXED);
  generation = cmux_trace__ld32_at(src, at + CMUX_TRACE_OFF_C_GENERATION, CMUX_TRACE__RELAXED);
  published = cmux_trace__ld32_at(src, at + CMUX_TRACE_OFF_C_PUBLISHED, CMUX_TRACE__RELAXED);
  second = cmux_trace__ld64_at(src, at + CMUX_TRACE_OFF_C_LAP_SEQ, CMUX_TRACE__RELAXED);
  if (cmux_trace_lap_of(second) != cmux_trace_lap_of(first)) return;
  cmux_trace__st32_at(dst, at + CMUX_TRACE_OFF_C_THREAD, thread, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(dst, at + CMUX_TRACE_OFF_C_GENERATION, generation, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(dst, at + CMUX_TRACE_OFF_C_PUBLISHED, published, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(dst, at + CMUX_TRACE_OFF_C_LAP_SEQ, first + (first & 1), CMUX_TRACE__RELEASE);
}

/* Copies `src` into the zeroed, private `dst` of the same layout while writers may run on `src`: the
 * header, every chunk, then the name and thread entries below the cursors loaded after the chunks
 * (a thread or name is published before its first record, so every copied chunk names an entry the
 * table copy finds). Returns the source `chunk_cursor` the tables were copied under. The copy of a
 * quiescent ring is its bytes. */
static inline uint64_t cmux_trace_ring_copy(const cmux_trace_ring *src, const cmux_trace_ring *dst) {
  const cmux_trace_sizes sizes = src->layout.sizes;
  uint32_t name_cursor, thread_cursor, index;
  uint64_t chunk_cursor;
  size_t at;
  for (at = 0; at < CMUX_TRACE_HEADER_BYTES; at += 8) {
    if (cmux_trace__header_u32_pair(at)) {
      cmux_trace__st32_at(dst, at, cmux_trace__ld32_at(src, at, CMUX_TRACE__RELAXED), CMUX_TRACE__RELAXED);
      cmux_trace__st32_at(dst, at + 4, cmux_trace__ld32_at(src, at + 4, CMUX_TRACE__RELAXED), CMUX_TRACE__RELAXED);
    } else {
      cmux_trace__st64_at(dst, at, cmux_trace__ld64_at(src, at, CMUX_TRACE__RELAXED), CMUX_TRACE__RELAXED);
    }
  }
  for (index = 0; index < sizes.chunk_count; index++) cmux_trace__copy_chunk(src, dst, cmux_trace__chunk(src, index));
  name_cursor = cmux_trace__ld32_at(src, CMUX_TRACE_OFF_NAME_CURSOR, CMUX_TRACE__ACQUIRE);
  thread_cursor = cmux_trace__ld32_at(src, CMUX_TRACE_OFF_THREAD_CURSOR, CMUX_TRACE__ACQUIRE);
  chunk_cursor = cmux_trace__ld64_at(src, CMUX_TRACE_OFF_CHUNK_CURSOR, CMUX_TRACE__ACQUIRE);
  for (index = 1; index < name_cursor && index < sizes.name_capacity; index++) {
    cmux_trace__copy_entry(src, dst, cmux_trace__name_entry(src, index), false);
  }
  for (index = 0; index < thread_cursor && index < sizes.thread_capacity; index++) {
    cmux_trace__copy_entry(src, dst, cmux_trace__thread_entry(src, index), true);
  }
  cmux_trace__st32_at(dst, CMUX_TRACE_OFF_NAME_CURSOR, name_cursor, CMUX_TRACE__RELAXED);
  cmux_trace__st32_at(dst, CMUX_TRACE_OFF_THREAD_CURSOR, thread_cursor, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(dst, CMUX_TRACE_OFF_CHUNK_CURSOR, chunk_cursor, CMUX_TRACE__RELAXED);
  return chunk_cursor;
}

/* ---- A process's rings and its one write path ("One write path"). ------------------------- */

/* The active word: bits 0-1 the active ring's slot, bit 2 "the black box is the file", bit 3 "a
 * recording runs", bits 8-63 the epoch, which grows at every change. */
#define CMUX_TRACE__SLOT_MASK UINT64_C(3)
#define CMUX_TRACE__BLACKBOX_IS_FILE (UINT64_C(1) << 2)
#define CMUX_TRACE__RECORDING_ON (UINT64_C(1) << 3)
#define CMUX_TRACE__EPOCH_ONE (UINT64_C(1) << 8)
#define CMUX_TRACE_SLOT_HEAP 0u
#define CMUX_TRACE_SLOT_FILE 1u
#define CMUX_TRACE_SLOT_RECORDING 2u
#define CMUX_TRACE_SLOTS 3u
#define CMUX_TRACE__IDLE 0u
#define CMUX_TRACE__CHANGING 1u
#define CMUX_TRACE__RECORDING 2u

/* A process's rings and trace state, like Chrome's TraceLog. The process keeps one (the Chromium
 * host's is task 104's); tests make their own. Every field after init is read and written atomically. */
typedef struct cmux_trace_tracer {
  cmux_trace_ring rings[CMUX_TRACE_SLOTS]; /* heap, black-box file, recording; set once, before their bit in `present` */
  uint32_t present;                        /* bit per slot whose ring is set (release) */
  uint32_t adopting;                       /* 1 once an adoption began: one file per black box */
  uint32_t control;                        /* idle, changing, recording: start and stop exclude each other, never wait */
  uint64_t active;
  uint64_t categories;
  uint64_t blackbox_categories;
} cmux_trace_tracer;

/* A tracer whose heap ring (initialised, black-box kind) is active at once. */
static inline void cmux_trace_tracer_init(cmux_trace_tracer *tracer, const cmux_trace_ring *heap,
                                          uint64_t blackbox_categories) {
  uint32_t slot;
  for (slot = 0; slot < CMUX_TRACE_SLOTS; slot++) tracer->rings[slot] = cmux_trace_ring_on(NULL, heap->layout);
  tracer->rings[CMUX_TRACE_SLOT_HEAP] = *heap;
  tracer->blackbox_categories = blackbox_categories;
  cmux_trace__st64(&tracer->categories, blackbox_categories, CMUX_TRACE__RELAXED);
  cmux_trace__st64(&tracer->active, CMUX_TRACE_SLOT_HEAP | CMUX_TRACE__EPOCH_ONE, CMUX_TRACE__RELAXED);
  cmux_trace__st32(&tracer->control, CMUX_TRACE__IDLE, CMUX_TRACE__RELAXED);
  cmux_trace__st32(&tracer->adopting, 0, CMUX_TRACE__RELAXED);
  cmux_trace__st32(&tracer->present, 1u << CMUX_TRACE_SLOT_HEAP, CMUX_TRACE__RELEASE);
}

/* Whether trace points of `category` record now: one relaxed load and a branch. */
static inline bool cmux_trace_enabled(cmux_trace_tracer *tracer, uint64_t category) {
  return (cmux_trace__ld64(&tracer->categories, CMUX_TRACE__RELAXED) & category) != 0;
}

static inline const cmux_trace_ring *cmux_trace__present_ring(cmux_trace_tracer *tracer, uint32_t slot) {
  return (cmux_trace__ld32(&tracer->present, CMUX_TRACE__ACQUIRE) >> slot & 1u) ? &tracer->rings[slot] : NULL;
}

static inline void cmux_trace__set_categories(cmux_trace_tracer *tracer, uint64_t categories) {
  uint32_t slot;
  cmux_trace__st64(&tracer->categories, categories, CMUX_TRACE__RELEASE);
  for (slot = 0; slot < CMUX_TRACE_SLOTS; slot++) {
    const cmux_trace_ring *ring = cmux_trace__present_ring(tracer, slot);
    if (ring) cmux_trace_ring_set_categories(ring, categories);
  }
}

/* The active ring now (status and snapshots; a writer reads the active word itself). */
static inline const cmux_trace_ring *cmux_trace_tracer_active_ring(cmux_trace_tracer *tracer) {
  uint64_t word = cmux_trace__ld64(&tracer->active, CMUX_TRACE__ACQUIRE);
  return &tracer->rings[word & CMUX_TRACE__SLOT_MASK];
}

/* One thread's place in a tracer's rings, kept in thread-local storage: its identity (read once),
 * its entry in each ring and the chunk it owns. Zero it with cmux_trace_writer_init. */
typedef struct cmux_trace_writer {
  cmux_trace_thread_identity identity;
  uint8_t has_identity;
  uint8_t registered; /* bit per ring slot */
  uint8_t owns_chunk;
  uint8_t busy; /* a signal handler that writes on this thread while it writes drops its record */
  uint32_t owned_slot;
  uint32_t entry_index[CMUX_TRACE_SLOTS];
  uint32_t entry_generation[CMUX_TRACE_SLOTS];
  uint32_t chunk;
  uint32_t next_slot;
  uint64_t epoch;
  uint64_t lap;
} cmux_trace_writer;

/* A writer with `identity`, or with none (read from the thread at its first record where the
 * platform allows; else tid 0 and no name). */
static inline void cmux_trace_writer_init(cmux_trace_writer *writer, const cmux_trace_thread_identity *identity) {
  uint32_t slot;
  writer->identity = cmux_trace_thread_identity_make(0, 0, "");
  writer->has_identity = identity != NULL;
  if (identity) writer->identity = *identity;
  writer->registered = 0;
  writer->owns_chunk = 0;
  writer->busy = 0;
  writer->owned_slot = 0;
  for (slot = 0; slot < CMUX_TRACE_SLOTS; slot++) writer->entry_index[slot] = writer->entry_generation[slot] = 0;
  writer->chunk = writer->next_slot = 0;
  writer->epoch = writer->lap = 0;
}

static inline void cmux_trace__writer_entry(cmux_trace_writer *writer, const cmux_trace_ring *ring, uint32_t slot) {
  if (writer->registered >> slot & 1u) return;
  if (!writer->has_identity) {
#if defined(CMUX_TRACE_HAS_CURRENT_THREAD)
    writer->identity = cmux_trace_thread_identity_current();
#endif
    writer->has_identity = 1;
  }
  cmux_trace_ring_register_thread(ring, &writer->identity, &writer->entry_index[slot],
                                  &writer->entry_generation[slot]);
  writer->registered = (uint8_t)(writer->registered | 1u << slot);
}

/* Writes `record` as `writer`'s thread into the active ring; with `interned`, under that name's id
 * in the ring (`record->name` is ignored). No lock or allocation; the read-modify-writes are the
 * chunk claim's, once per 31 records. The caller checks the category (cmux_trace_enabled). */
static inline void cmux_trace_write_named(cmux_trace_tracer *tracer, cmux_trace_writer *writer,
                                          const cmux_trace_record *record, cmux_trace_interned_name *interned) {
  uint64_t word = cmux_trace__ld64(&tracer->active, CMUX_TRACE__ACQUIRE);
  uint32_t slot = (uint32_t)(word & CMUX_TRACE__SLOT_MASK);
  uint64_t epoch = word >> 8;
  const cmux_trace_ring *ring = &tracer->rings[slot];
  cmux_trace_record out = *record;
  if (writer->busy) return;
  writer->busy = 1;
  if (writer->owns_chunk && writer->epoch != epoch) {
    cmux_trace_ring_complete(&tracer->rings[writer->owned_slot], writer->chunk, writer->lap);
    writer->owns_chunk = 0;
  }
  cmux_trace__writer_entry(writer, ring, slot);
  if (interned) {
    uint32_t shift = 16 * slot;
    uint16_t id = (uint16_t)(cmux_trace__ld64(&interned->ids, CMUX_TRACE__RELAXED) >> shift);
    if (id == 0) {
      id = cmux_trace_ring_intern(ring, interned->text, interned->category);
      if (id != 0) {
        uint64_t ids = cmux_trace__ld64(&interned->ids, CMUX_TRACE__RELAXED);
        while ((uint16_t)(ids >> shift) == 0 &&
               !cmux_trace__cas64(&interned->ids, &ids, ids | (uint64_t)id << shift, CMUX_TRACE__RELAXED,
                                  CMUX_TRACE__RELAXED)) {
        }
        id = (uint16_t)(ids >> shift) != 0 ? (uint16_t)(ids >> shift) : id;
      }
    }
    out.name = id;
  }
  if (!writer->owns_chunk) {
    if (!cmux_trace_ring_claim(ring, writer->entry_index[slot], writer->entry_generation[slot], &writer->chunk,
                               &writer->lap)) {
      writer->busy = 0;
      return;
    }
    writer->owns_chunk = 1;
    writer->owned_slot = slot;
    writer->epoch = epoch;
    writer->next_slot = 1;
  }
  cmux_trace_ring_publish(ring, writer->chunk, writer->lap, writer->next_slot, &out);
  if (writer->next_slot == CMUX_TRACE_RECORDS_PER_CHUNK) {
    cmux_trace_ring_complete(ring, writer->chunk, writer->lap);
    writer->owns_chunk = 0;
  } else {
    writer->next_slot++;
  }
  writer->busy = 0;
}

static inline void cmux_trace_write(cmux_trace_tracer *tracer, cmux_trace_writer *writer,
                                    const cmux_trace_record *record) {
  cmux_trace_write_named(tracer, writer, record, NULL);
}

#if defined(CMUX_TRACE_HAS_CLOCK)
/* A trace point: catalog name `name` with `phase` now, if `category` is on. */
static inline void cmux_trace_point(cmux_trace_tracer *tracer, cmux_trace_writer *writer, uint64_t category,
                                    uint16_t name, uint8_t phase, uint8_t flags, uint64_t arg0, uint64_t arg1) {
  cmux_trace_record record;
  if (!cmux_trace_enabled(tracer, category)) return;
  record.t_ns = cmux_trace_now_ns();
  record.name = name;
  record.phase = phase;
  record.flags = flags;
  record.arg0 = arg0;
  record.arg1 = arg1;
  cmux_trace_write(tracer, writer, &record);
}
#endif

/* A thread's exit (its thread-local destructor): completes its chunk and marks each of its entries
 * exited, so a later thread may take them. */
static inline void cmux_trace_writer_exit(cmux_trace_tracer *tracer, cmux_trace_writer *writer) {
  uint32_t slot;
  if (writer->owns_chunk) cmux_trace_ring_complete(&tracer->rings[writer->owned_slot], writer->chunk, writer->lap);
  for (slot = 0; slot < CMUX_TRACE_SLOTS; slot++) {
    if (writer->registered >> slot & 1u) cmux_trace_ring_exit_thread(&tracer->rings[slot], writer->entry_index[slot]);
  }
  cmux_trace_writer_init(writer, NULL);
}

/* Updates the active word with `next(word)` (a compare-exchange loop; it never waits on a writer). */
static inline void cmux_trace__update_active(cmux_trace_tracer *tracer, uint64_t (*next)(uint64_t)) {
  uint64_t word = cmux_trace__ld64(&tracer->active, CMUX_TRACE__ACQUIRE);
  while (!cmux_trace__cas64(&tracer->active, &word, next(word), CMUX_TRACE__ACQ_REL, CMUX_TRACE__ACQUIRE)) {
  }
}

static inline uint64_t cmux_trace__to_file(uint64_t word) {
  if (word & CMUX_TRACE__RECORDING_ON) return word | CMUX_TRACE__BLACKBOX_IS_FILE;
  return ((word & ~CMUX_TRACE__SLOT_MASK) | CMUX_TRACE_SLOT_FILE | CMUX_TRACE__BLACKBOX_IS_FILE) +
         CMUX_TRACE__EPOCH_ONE;
}

static inline uint64_t cmux_trace__to_recording(uint64_t word) {
  return ((word & ~CMUX_TRACE__SLOT_MASK) | CMUX_TRACE_SLOT_RECORDING | CMUX_TRACE__RECORDING_ON) +
         CMUX_TRACE__EPOCH_ONE;
}

static inline uint64_t cmux_trace__to_blackbox(uint64_t word) {
  uint64_t blackbox = (word & CMUX_TRACE__BLACKBOX_IS_FILE) ? CMUX_TRACE_SLOT_FILE : CMUX_TRACE_SLOT_HEAP;
  return ((word & ~(CMUX_TRACE__SLOT_MASK | CMUX_TRACE__RECORDING_ON)) | blackbox) + CMUX_TRACE__EPOCH_ONE;
}

/* "Heap, then file": copies the heap ring into `file` (zeroed MAP_SHARED memory of the heap's layout,
 * still private), writes the identity fields read off the hot path, then makes it the black box
 * (copy first, swap last, so no writer claims in the file before the copy is done). Call it once, off
 * the main thread; the heap block stays allocated for the process's life. */
static inline cmux_trace_error cmux_trace_tracer_adopt(cmux_trace_tracer *tracer, const cmux_trace_ring *file,
                                                       uint64_t process_start_unix_us,
                                                       const uint8_t boot_session_uuid[16]) {
  const cmux_trace_ring *heap = &tracer->rings[CMUX_TRACE_SLOT_HEAP];
  uint64_t copied, lost, count = heap->layout.sizes.chunk_count;
  uint32_t idle = 0;
  if (!cmux_trace_layout_equal(&heap->layout, &file->layout)) return CMUX_TRACE_ERROR_LAYOUT_MISMATCH;
  if (!cmux_trace__cas32(&tracer->adopting, &idle, 1, CMUX_TRACE__ACQ_REL, CMUX_TRACE__RELAXED)) {
    return CMUX_TRACE_ERROR_ALREADY_ATTACHED;
  }
  copied = cmux_trace_ring_copy(heap, file);
  cmux_trace_ring_put_slow_identity(file, process_start_unix_us, boot_session_uuid);
  cmux_trace__st64_at(file, CMUX_TRACE_OFF_HEAP_CURSOR, copied, CMUX_TRACE__RELAXED);
  cmux_trace__st64_at(file, CMUX_TRACE_OFF_CHUNK_CURSOR, copied + count, CMUX_TRACE__RELAXED);
  cmux_trace_ring_set_categories(file, cmux_trace__ld64(&tracer->categories, CMUX_TRACE__RELAXED));
  tracer->rings[CMUX_TRACE_SLOT_FILE] = *file;
  cmux_trace__add32(&tracer->present, 1u << CMUX_TRACE_SLOT_FILE, CMUX_TRACE__RELEASE);
  cmux_trace__update_active(tracer, cmux_trace__to_file);
  lost = cmux_trace__ld64_at(heap, CMUX_TRACE_OFF_CHUNK_CURSOR, CMUX_TRACE__RELAXED) - copied;
  cmux_trace__st32_at(file, CMUX_TRACE_OFF_HEAP_CHUNKS_LOST, lost > UINT32_MAX ? UINT32_MAX : (uint32_t)lost,
                      CMUX_TRACE__RELAXED);
  return CMUX_TRACE_OK;
}

/* Gives the tracer its recording ring (initialised, recording kind, mapped once and never unmapped
 * or cleared): before the first trace.start, once. */
static inline cmux_trace_error cmux_trace_tracer_attach_recording(cmux_trace_tracer *tracer,
                                                                  const cmux_trace_ring *recording) {
  uint32_t expected = CMUX_TRACE__IDLE;
  cmux_trace_error error = CMUX_TRACE_OK;
  if (!cmux_trace__cas32(&tracer->control, &expected, CMUX_TRACE__CHANGING, CMUX_TRACE__ACQ_REL,
                         CMUX_TRACE__ACQUIRE)) {
    return CMUX_TRACE_ERROR_ALREADY_RECORDING;
  }
  if (cmux_trace__present_ring(tracer, CMUX_TRACE_SLOT_RECORDING)) {
    error = CMUX_TRACE_ERROR_ALREADY_ATTACHED;
  } else {
    tracer->rings[CMUX_TRACE_SLOT_RECORDING] = *recording;
    cmux_trace__add32(&tracer->present, 1u << CMUX_TRACE_SLOT_RECORDING, CMUX_TRACE__RELEASE);
  }
  cmux_trace__st32(&tracer->control, CMUX_TRACE__IDLE, CMUX_TRACE__RELEASE);
  return error;
}

/* trace.start: the black-box categories plus `categories`, into the recording ring (step 3 swaps). */
static inline cmux_trace_error cmux_trace_tracer_start_recording(cmux_trace_tracer *tracer, uint64_t categories,
                                                                 uint64_t uptime_ns, uint64_t unix_ns,
                                                                 uint64_t continuous_ns) {
  uint32_t expected = CMUX_TRACE__IDLE;
  const cmux_trace_ring *ring;
  if (!cmux_trace__cas32(&tracer->control, &expected, CMUX_TRACE__CHANGING, CMUX_TRACE__ACQ_REL,
                         CMUX_TRACE__ACQUIRE)) {
    return CMUX_TRACE_ERROR_ALREADY_RECORDING;
  }
  ring = cmux_trace__present_ring(tracer, CMUX_TRACE_SLOT_RECORDING);
  if (!ring) {
    cmux_trace__st32(&tracer->control, CMUX_TRACE__IDLE, CMUX_TRACE__RELEASE);
    return CMUX_TRACE_ERROR_NO_RECORDING_RING;
  }
  cmux_trace_ring_begin_recording(ring, uptime_ns, unix_ns, continuous_ns);
  cmux_trace__update_active(tracer, cmux_trace__to_recording);
  cmux_trace__set_categories(tracer, tracer->blackbox_categories | categories);
  cmux_trace__st32(&tracer->control, CMUX_TRACE__RECORDING, CMUX_TRACE__RELEASE);
  return CMUX_TRACE_OK;
}

/* trace.stop: back to the black-box categories and the black box. The recording ring keeps what it
 * holds until the next start. */
static inline cmux_trace_error cmux_trace_tracer_stop(cmux_trace_tracer *tracer) {
  uint32_t expected = CMUX_TRACE__RECORDING;
  if (!cmux_trace__cas32(&tracer->control, &expected, CMUX_TRACE__CHANGING, CMUX_TRACE__ACQ_REL,
                         CMUX_TRACE__ACQUIRE)) {
    return CMUX_TRACE_ERROR_NOT_RECORDING;
  }
  cmux_trace__set_categories(tracer, tracer->blackbox_categories);
  cmux_trace__update_active(tracer, cmux_trace__to_blackbox);
  cmux_trace__st32(&tracer->control, CMUX_TRACE__IDLE, CMUX_TRACE__RELEASE);
  return CMUX_TRACE_OK;
}

/* ---- Crash-key page. --------------------------------------------------------------------- */
/* A fixed-slot 4 KiB page of 64-bit words per process, written with relaxed stores while it runs
 * and read from its file after a crash or a fatal hang. Chrome's crash keys
 * (components/crash/core/common/crash_key.h) are static-storage values the out-of-process handler
 * reads from the dead process; setting one is a store, not an allocation. Values are ids, counts,
 * states and times only, never a person's text.
 *
 * Words 0-7 are the page header:
 *   0   8  magic        ASCII "CMXCKEYS"
 *   8   4  version u32  1
 *   12  2  role u16     the ring header's role
 *   14  2  header_words u16  8
 *   16  4  pid u32
 *   20  4  page_words u32    512
 *   24  8  process_start_unix_us u64
 *   32  16 build_uuid
 *   48  8  start_uptime_ns u64 (the trace clock when the page was made)
 *   56  8  reserved, zero
 * The slots are CrashKeySlot.swift's (its raw value is the slot's first word; fixed, append-only);
 * a process sets the ones that apply to it. cmux_trace_test.c checks the two tables agree. */

#define CMUX_CRASH_KEYS_MAGIC "CMXCKEYS"
#define CMUX_CRASH_KEYS_VERSION 1u
#define CMUX_CRASH_KEYS_PAGE_BYTES 4096u
#define CMUX_CRASH_KEYS_PAGE_WORDS 512u
#define CMUX_CRASH_KEYS_HEADER_WORDS 8u

#define CMUX_CRASH_KEY_ACTION_INDEX 8u
#define CMUX_CRASH_KEY_ACTION_ENTRYPOINT 9u
#define CMUX_CRASH_KEY_MAIN_TASK_OWNER 10u
#define CMUX_CRASH_KEY_IN_CEF_PUMP 11u
#define CMUX_CRASH_KEY_LAST_INPUT_UPTIME 12u
#define CMUX_CRASH_KEY_WINDOW_COUNT 13u
#define CMUX_CRASH_KEY_WORKSPACE_COUNT 14u
#define CMUX_CRASH_KEY_TERMINAL_COUNT 15u
#define CMUX_CRASH_KEY_CHROMIUM_BROWSER_COUNT 16u
#define CMUX_CRASH_KEY_WEBKIT_VIEW_COUNT 17u
#define CMUX_CRASH_KEY_DAEMON_PID 18u
#define CMUX_CRASH_KEY_DAEMON_STATE 19u
#define CMUX_CRASH_KEY_CEF_API_VERSION 20u
#define CMUX_CRASH_KEY_GHOSTTY_COMMIT 21u
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_START 22u
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAME_COUNT 23u
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_IMAGES 24u /* 32 words */
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAMES 56u /* 64 words */
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_IMAGES_WORDS 32u
#define CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAMES_WORDS 64u

typedef struct cmux_crash_keys {
  uint8_t *base; /* 4096 bytes, 8-byte aligned, zeroed before init; never unmapped while the process runs */
} cmux_crash_keys;

/* Writes the header of a zeroed page; the magic goes last (release), so a reader that finds it finds
 * the rest. */
static inline cmux_crash_keys cmux_crash_keys_init(void *zeroed_page, uint16_t role, uint32_t pid,
                                                   uint64_t process_start_unix_us, const uint8_t build_uuid[16],
                                                   uint64_t start_uptime_ns) {
  cmux_crash_keys keys;
  const uint8_t magic[8] = {'C', 'M', 'X', 'C', 'K', 'E', 'Y', 'S'};
  uint64_t magic_word = 0, uuid_low = 0, uuid_high = 0;
  size_t index;
  keys.base = (uint8_t *)zeroed_page;
  for (index = 0; index < 8; index++) {
    magic_word |= (uint64_t)magic[index] << (8 * index);
    uuid_low |= (uint64_t)build_uuid[index] << (8 * index);
    uuid_high |= (uint64_t)build_uuid[8 + index] << (8 * index);
  }
  cmux_trace__st32(keys.base + 8, CMUX_CRASH_KEYS_VERSION, CMUX_TRACE__RELAXED);
  cmux_trace__st32(keys.base + 12, (uint32_t)role | (uint32_t)CMUX_CRASH_KEYS_HEADER_WORDS << 16, CMUX_TRACE__RELAXED);
  cmux_trace__st32(keys.base + 16, pid, CMUX_TRACE__RELAXED);
  cmux_trace__st32(keys.base + 20, CMUX_CRASH_KEYS_PAGE_WORDS, CMUX_TRACE__RELAXED);
  cmux_trace__st64(keys.base + 24, process_start_unix_us, CMUX_TRACE__RELAXED);
  cmux_trace__st64(keys.base + 32, uuid_low, CMUX_TRACE__RELAXED);
  cmux_trace__st64(keys.base + 40, uuid_high, CMUX_TRACE__RELAXED);
  cmux_trace__st64(keys.base + 48, start_uptime_ns, CMUX_TRACE__RELAXED);
  cmux_trace__st64(keys.base, magic_word, CMUX_TRACE__RELEASE);
  return keys;
}

/* Word `word` of the slot that starts at word `slot` (0 for a one-word slot): one relaxed store.
 * False, and nothing stored, for a word in the header or past the page. */
static inline bool cmux_crash_keys_set_word(cmux_crash_keys keys, uint32_t slot, uint32_t word, uint64_t value) {
  uint32_t at = slot + word;
  if (slot < CMUX_CRASH_KEYS_HEADER_WORDS || at < slot || at >= CMUX_CRASH_KEYS_PAGE_WORDS) return false;
  cmux_trace__st64(keys.base + (size_t)at * 8, value, CMUX_TRACE__RELAXED);
  return true;
}

static inline bool cmux_crash_keys_set(cmux_crash_keys keys, uint32_t slot, uint64_t value) {
  return cmux_crash_keys_set_word(keys, slot, 0, value);
}

/* The value a slot's word holds now (0 when never set or out of range). */
static inline uint64_t cmux_crash_keys_get_word(cmux_crash_keys keys, uint32_t slot, uint32_t word) {
  uint32_t at = slot + word;
  if (slot < CMUX_CRASH_KEYS_HEADER_WORDS || at < slot || at >= CMUX_CRASH_KEYS_PAGE_WORDS) return 0;
  return cmux_trace__ld64(keys.base + (size_t)at * 8, CMUX_TRACE__RELAXED);
}

static inline uint64_t cmux_crash_keys_get(cmux_crash_keys keys, uint32_t slot) {
  return cmux_crash_keys_get_word(keys, slot, 0);
}

#endif /* CMUX_TRACE_H */
