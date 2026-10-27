/* Tests of cmux_trace.h (scripts/cmux-next/test-cmux-trace-c.sh builds and runs them):
 * - the golden ring of cmux-tui/crates/cmux-trace/tests/ring.rs, built here, equals the shared
 *   fixture byte for byte (the file the Rust and Swift writers compare with), raw and as a copy;
 * - 8 threads decode exactly once in per-thread order; overwrite keeps only whole, newest records;
 *   a writer stopped inside a record keeps its chunk and its record never decodes torn;
 * - heap-then-file adoption, recordings (start, stop, a lap past the last), thread entry reuse;
 * - the crash-key page: its slots agree with CrashKeySlot.swift, its header with CrashKeys.swift,
 *   and its bytes with the fixture CrashKeysTests decodes;
 * - the header names no allocator, mapping or lock (poisoned below, so it would not compile).
 *
 * Usage: cmux_trace_test GOLDEN_FILE CRASH_KEY_SLOT_SWIFT CRASH_KEYS_SWIFT CRASH_KEYS_FIXTURE */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

/* The test's own memory, taken before the poison below. */
static void *test_zeroed(size_t bytes) {
  void *block = calloc(1, bytes);
  if (!block) {
    fprintf(stderr, "out of memory\n");
    exit(2);
  }
  return block;
}

static void test_release(void *block) { free(block); }

/* A whole file, NUL terminated, or NULL. */
static uint8_t *read_file(const char *path, size_t *length) {
  FILE *file = fopen(path, "rb");
  uint8_t *bytes = NULL;
  long size = -1;
  if (!file) return NULL;
  if (fseek(file, 0, SEEK_END) == 0) size = ftell(file);
  if (size >= 0 && fseek(file, 0, SEEK_SET) == 0) {
    bytes = (uint8_t *)test_zeroed((size_t)size + 1);
    if (fread(bytes, 1, (size_t)size, file) != (size_t)size) {
      free(bytes);
      bytes = NULL;
    }
  }
  fclose(file);
  if (bytes) *length = (size_t)size;
  return bytes;
}

/* No allocation, mapping, file or lock in the header: any use of these after here fails to compile. */
#pragma GCC poison malloc calloc realloc free aligned_alloc posix_memalign mmap munmap open fopen
#pragma GCC poison pthread_mutex_lock pthread_rwlock_wrlock pthread_rwlock_rdlock os_unfair_lock_lock
#pragma GCC poison sem_wait pthread_cond_wait dispatch_sync usleep nanosleep sleep

#include "cmux_trace.h"

static int failures = 0;

#define CHECK(cond)                                                                \
  do {                                                                             \
    if (!(cond)) {                                                                 \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);     \
      failures++;                                                                  \
    }                                                                              \
  } while (0)

#define CHECK_EQ_U64(a, b)                                                                              \
  do {                                                                                                  \
    uint64_t check_a = (uint64_t)(a), check_b = (uint64_t)(b);                                          \
    if (check_a != check_b) {                                                                           \
      fprintf(stderr, "%s:%d: %s == %s failed: %llu != %llu\n", __FILE__, __LINE__, #a, #b,             \
              (unsigned long long)check_a, (unsigned long long)check_b);                                \
      failures++;                                                                                       \
    }                                                                                                   \
  } while (0)

static uint16_t u16_at(const uint8_t *bytes, size_t at) { return (uint16_t)(bytes[at] | bytes[at + 1] << 8); }
static uint32_t u32_at(const uint8_t *bytes, size_t at) {
  return (uint32_t)bytes[at] | (uint32_t)bytes[at + 1] << 8 | (uint32_t)bytes[at + 2] << 16 |
         (uint32_t)bytes[at + 3] << 24;
}
static uint64_t u64_at(const uint8_t *bytes, size_t at) {
  return (uint64_t)u32_at(bytes, at) | (uint64_t)u32_at(bytes, at + 4) << 32;
}

/* ---- A decoder of trace.md "Decode a chunk", for the tests (a ring no writer touches). ---- */

typedef struct decoded_record {
  uint64_t t_ns;
  uint32_t thread;
  uint32_t generation;
  uint16_t name;
  uint8_t phase;
  uint8_t flags;
  uint64_t arg0;
  uint64_t arg1;
} decoded_record;

/* Decodes up to `max` records of `bytes` into `out` in chunk then slot order; the count. */
static size_t decode_ring(const uint8_t *bytes, decoded_record *out, size_t max) {
  uint64_t chunks_offset = u64_at(bytes, CMUX_TRACE_OFF_CHUNKS_OFFSET);
  uint32_t chunk_count = u32_at(bytes, CMUX_TRACE_OFF_CHUNK_COUNT);
  uint64_t start_lap = u64_at(bytes, CMUX_TRACE_OFF_RECORDING_START_CURSOR) / chunk_count;
  uint64_t start_uptime = u64_at(bytes, CMUX_TRACE_OFF_START_UPTIME_NS);
  size_t count = 0;
  uint32_t chunk, slot;
  for (chunk = 0; chunk < chunk_count; chunk++) {
    size_t at = (size_t)chunks_offset + (size_t)chunk * CMUX_TRACE_CHUNK_BYTES;
    uint64_t lap_seq = u64_at(bytes, at + CMUX_TRACE_OFF_C_LAP_SEQ), lap;
    if (lap_seq == 0) continue;
    lap = cmux_trace_lap_of(lap_seq);
    if (lap < start_lap) continue;
    for (slot = 1; slot <= CMUX_TRACE_RECORDS_PER_CHUNK; slot++) {
      size_t record = at + (size_t)slot * CMUX_TRACE_RECORD_BYTES;
      decoded_record decoded;
      if (u32_at(bytes, record + CMUX_TRACE_OFF_R_SEQ) != (uint32_t)cmux_trace_lap_complete(lap)) continue;
      decoded.t_ns = u64_at(bytes, record + CMUX_TRACE_OFF_R_T_NS);
      if (decoded.t_ns < start_uptime) continue;
      decoded.thread = u32_at(bytes, at + CMUX_TRACE_OFF_C_THREAD);
      decoded.generation = u32_at(bytes, at + CMUX_TRACE_OFF_C_GENERATION);
      decoded.name = u16_at(bytes, record + 12);
      decoded.phase = bytes[record + 14];
      decoded.flags = bytes[record + 15];
      decoded.arg0 = u64_at(bytes, record + CMUX_TRACE_OFF_R_ARG0);
      decoded.arg1 = u64_at(bytes, record + CMUX_TRACE_OFF_R_ARG1);
      if (count < max) out[count] = decoded;
      count++;
    }
  }
  return count;
}

/* ---- Helpers. ---------------------------------------------------------------------------- */

static cmux_trace_sizes test_sizes(uint32_t chunks) {
  cmux_trace_sizes sizes = {64, 256, chunks};
  return sizes;
}

static cmux_trace_header_fields test_fields(uint8_t kind) {
  cmux_trace_header_fields fields;
  memset(&fields, 0, sizeof fields);
  fields.pid = 1;
  fields.role = CMUX_TRACE_ROLE_CHROMIUM_HOST;
  fields.ring_kind = kind;
  fields.clock_domain = CMUX_TRACE_CLOCK_UPTIME_RAW;
  fields.categories = CMUX_TRACE_CAT_BLACKBOX;
  return fields;
}

static const cmux_trace_catalog_name test_catalog[3] = {
    {1, CMUX_TRACE_NAME_CATALOG, 1, "key.frame"},
    {2, CMUX_TRACE_NAME_CATALOG, 6, "daemon.request"},
    {3, CMUX_TRACE_NAME_CATEGORY, 1, "key"},
};

static cmux_trace_ring test_ring(uint32_t chunks, uint8_t kind) {
  cmux_trace_layout layout = cmux_trace_layout_of(test_sizes(chunks));
  cmux_trace_ring ring = cmux_trace_ring_on(test_zeroed(layout.total_bytes), layout);
  cmux_trace_header_fields fields = test_fields(kind);
  cmux_trace_ring_init(&ring, &fields, test_catalog, 3);
  return ring;
}

static cmux_trace_record make_record(uint64_t t_ns, uint16_t name, uint8_t phase, uint8_t flags, uint64_t arg0,
                                     uint64_t arg1) {
  cmux_trace_record record;
  record.t_ns = t_ns;
  record.name = name;
  record.phase = phase;
  record.flags = flags;
  record.arg0 = arg0;
  record.arg1 = arg1;
  return record;
}

/* ---- The golden ring (tests/ring.rs, golden_bytes). -------------------------------------- */

static void test_golden(const char *golden_path) {
  cmux_trace_layout layout = cmux_trace_layout_of(test_sizes(4));
  cmux_trace_ring heap = cmux_trace_ring_on(test_zeroed(layout.total_bytes), layout);
  cmux_trace_ring copy = cmux_trace_ring_on(test_zeroed(layout.total_bytes), layout);
  cmux_trace_header_fields fields;
  cmux_trace_tracer tracer;
  cmux_trace_writer main_writer, io_writer;
  cmux_trace_thread_identity main_identity = cmux_trace_thread_identity_make(101, 0x21, "main");
  cmux_trace_thread_identity io_identity = cmux_trace_thread_identity_make(202, 0x19, "cmux-io");
  cmux_trace_interned_name read_name = {"cmux.io.read", 6, 0};
  cmux_trace_record record;
  decoded_record decoded[64];
  const char version[] = "1.2.3 (45) abcdef0";
  uint8_t *golden;
  size_t golden_length = 0, index, count;
  uint64_t step;

  CHECK_EQ_U64(layout.name_table_offset, 16384);
  CHECK_EQ_U64(layout.thread_table_offset, 32768);
  CHECK_EQ_U64(layout.chunks_offset, 49152);
  CHECK_EQ_U64(layout.total_bytes, 53248);

  memset(&fields, 0, sizeof fields);
  fields.pid = 4242;
  fields.role = CMUX_TRACE_ROLE_DAEMON;
  fields.ring_kind = CMUX_TRACE_RING_BLACK_BOX;
  fields.clock_domain = CMUX_TRACE_CLOCK_UPTIME_RAW;
  fields.start_uptime_ns = 1000;
  fields.start_unix_ns = UINT64_C(1700000000000000000);
  fields.start_continuous_ns = 2000;
  fields.process_start_unix_us = UINT64_C(1699999999000000);
  for (index = 0; index < 16; index++) {
    fields.boot_session_uuid[index] = (uint8_t)(0x10 + index);
    fields.build_uuid[index] = (uint8_t)(0x20 + index);
  }
  memcpy(fields.build_version, version, sizeof version - 1);
  fields.categories = CMUX_TRACE_CAT_BLACKBOX;
  cmux_trace_ring_init(&heap, &fields, test_catalog, 3);
  cmux_trace_tracer_init(&tracer, &heap, CMUX_TRACE_CAT_BLACKBOX);
  cmux_trace_writer_init(&main_writer, &main_identity);
  cmux_trace_writer_init(&io_writer, &io_identity);

  record = make_record(1000, 1, CMUX_TRACE_PHASE_BEGIN, 0, 7, 0);
  cmux_trace_write(&tracer, &main_writer, &record);
  record = make_record(1050, 2, CMUX_TRACE_PHASE_ASYNC_BEGIN, CMUX_TRACE_FLAG_ID, 0, 5);
  cmux_trace_write(&tracer, &io_writer, &record);
  record = make_record(1100, 1, CMUX_TRACE_PHASE_FLOW_OUT, 0, 0, 99);
  cmux_trace_write(&tracer, &main_writer, &record);
  record = make_record(1150, 2, CMUX_TRACE_PHASE_FLOW_IN, 0, 0, 99);
  cmux_trace_write(&tracer, &io_writer, &record);
  record = make_record(1200, 1, CMUX_TRACE_PHASE_END, 0, 0, 0);
  cmux_trace_write(&tracer, &main_writer, &record);
  record = make_record(1300, 2, CMUX_TRACE_PHASE_ASYNC_END, CMUX_TRACE_FLAG_ID, 0, 5);
  cmux_trace_write(&tracer, &io_writer, &record);
  record = make_record(1350, 2, CMUX_TRACE_PHASE_COUNTER, CMUX_TRACE_FLAG_ID | CMUX_TRACE_FLAG_ESTIMATE, 42, 3);
  cmux_trace_write(&tracer, &io_writer, &record);
  record = make_record(1375, 0, CMUX_TRACE_PHASE_INSTANT, 0, 8, 0);
  cmux_trace_write_named(&tracer, &io_writer, &record, &read_name);
  for (step = 0; step < 30; step++) {
    record = make_record(1400 + step, 1, CMUX_TRACE_PHASE_INSTANT, 0, step, 4);
    cmux_trace_write(&tracer, &main_writer, &record);
  }
  cmux_trace_writer_exit(&tracer, &main_writer);
  cmux_trace_writer_exit(&tracer, &io_writer);
  CHECK_EQ_U64(read_name.ids, 4);

  golden = read_file(golden_path, &golden_length);
  CHECK(golden != NULL);
  if (golden) {
    CHECK_EQ_U64(golden_length, layout.total_bytes);
    if (golden_length == layout.total_bytes) {
      size_t first_diff = golden_length;
      for (index = 0; index < golden_length; index++) {
        if (golden[index] != heap.base[index]) {
          first_diff = index;
          break;
        }
      }
      if (first_diff != golden_length) {
        fprintf(stderr, "golden ring differs at byte %zu: C 0x%02x, fixture 0x%02x\n", first_diff,
                heap.base[first_diff], golden[first_diff]);
      }
      CHECK(first_diff == golden_length);
      cmux_trace_ring_copy(&heap, &copy);
      CHECK(memcmp(copy.base, golden, golden_length) == 0);
    }
    count = decode_ring(golden, decoded, 64);
    CHECK_EQ_U64(count, 38);
    CHECK_EQ_U64(decoded[0].t_ns, 1000);
    CHECK_EQ_U64(decoded[0].phase, 'B');
    CHECK_EQ_U64(decoded[0].thread, 0);
    test_release(golden);
  }
  test_release(heap.base);
  test_release(copy.base);
}

/* ---- Every field at its trace.md offset (raw bytes, not through the header's accessors). ---- */

static void test_offsets(void) {
  cmux_trace_ring ring = test_ring(4, CMUX_TRACE_RING_RECORDING);
  const uint8_t *b = ring.base;
  CHECK(memcmp(b, "CMXTRACE", 8) == 0);
  CHECK_EQ_U64(u32_at(b, 8), 1);
  CHECK_EQ_U64(u32_at(b, 12), 256);
  CHECK_EQ_U64(u16_at(b, 20), CMUX_TRACE_ROLE_CHROMIUM_HOST);
  CHECK_EQ_U64(b[22], CMUX_TRACE_RING_RECORDING);
  CHECK_EQ_U64(b[23], CMUX_TRACE_CLOCK_UPTIME_RAW);
  CHECK_EQ_U64(u32_at(b, 112), 1024);
  CHECK_EQ_U64(u32_at(b, 116), 4);
  CHECK_EQ_U64(u64_at(b, 120), 49152);
  CHECK_EQ_U64(u64_at(b, 136), 16384);
  CHECK_EQ_U64(u32_at(b, 144), 64);
  CHECK_EQ_U64(u32_at(b, 148), 4);
  CHECK_EQ_U64(u64_at(b, 152), 32768);
  CHECK_EQ_U64(u32_at(b, 160), 256);
  CHECK_EQ_U64(u64_at(b, 168), 0x1ff);
  CHECK_EQ_U64(u32_at(b, 16384 + 64 + 4) & 0xffff, 1);
  CHECK(memcmp(b + 16384 + 2 * 64 + 9, "daemon.request", 14) == 0);
  test_release(ring.base);

  /* Sizes by role, and the normalisation the Rust layout applies. */
  {
    cmux_trace_sizes sizes = cmux_trace_role_sizes(CMUX_TRACE_ROLE_CHROMIUM_HOST, CMUX_TRACE_RING_BLACK_BOX);
    cmux_trace_sizes odd = {0, 300, 5};
    CHECK_EQ_U64(sizes.chunk_count, 512);
    CHECK_EQ_U64(cmux_trace_role_sizes(CMUX_TRACE_ROLE_CHROMIUM_HOST, CMUX_TRACE_RING_RECORDING).chunk_count, 8192);
    CHECK_EQ_U64(cmux_trace_role_sizes(CMUX_TRACE_ROLE_TERMINAL_HOST, CMUX_TRACE_RING_BLACK_BOX).chunk_count, 64);
    odd = cmux_trace_sizes_normalized(odd);
    CHECK_EQ_U64(odd.name_capacity, 1);
    CHECK_EQ_U64(odd.thread_capacity, 512);
    CHECK_EQ_U64(odd.chunk_count, 8);
  }
  /* A name is cut on a UTF-8 boundary: 54 ASCII bytes and a 2-byte character keep 54 bytes. */
  {
    char text[64];
    memset(text, 'a', 54);
    text[54] = (char)0xC3;
    text[55] = (char)0xA9;
    text[56] = '\0';
    CHECK_EQ_U64(cmux_trace__utf8_prefix(text, 55), 54);
    CHECK_EQ_U64(cmux_trace__utf8_prefix("key", 55), 3);
  }
}

/* ---- 8 threads: every record decodes exactly once, in per-thread order. ------------------- */

#define CONTENDED_THREADS 8
#define CONTENDED_RECORDS 100000

typedef struct contended_job {
  cmux_trace_tracer *tracer;
  uint32_t thread;
  _Atomic(uint32_t) *ready;
} contended_job;

static void *contended_writer(void *argument) {
  contended_job *job = (contended_job *)argument;
  cmux_trace_writer writer;
  cmux_trace_thread_identity identity = cmux_trace_thread_identity_make(1000 + job->thread, 0, "writer");
  uint64_t index;
  cmux_trace_writer_init(&writer, &identity);
  atomic_fetch_add(job->ready, 1);
  while (atomic_load(job->ready) < CONTENDED_THREADS) {
  }
  for (index = 0; index < CONTENDED_RECORDS; index++) {
    cmux_trace_record record = make_record(index + 1, 1, CMUX_TRACE_PHASE_INSTANT, 0, job->thread, index);
    cmux_trace_write(job->tracer, &writer, &record);
  }
  cmux_trace_writer_exit(job->tracer, &writer);
  return NULL;
}

static void test_contended(void) {
  /* Room for every record (no overwrite): 8 x 100k / 31 chunks, rounded to a power of two. */
  cmux_trace_ring ring = test_ring(32768, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_tracer tracer;
  pthread_t threads[CONTENDED_THREADS];
  contended_job jobs[CONTENDED_THREADS];
  _Atomic(uint32_t) ready = 0;
  size_t capacity = (size_t)32768 * CMUX_TRACE_RECORDS_PER_CHUNK, count, index;
  decoded_record *decoded = (decoded_record *)test_zeroed(capacity * sizeof(decoded_record));
  uint64_t *next = (uint64_t *)test_zeroed(CONTENDED_THREADS * sizeof(uint64_t));
  uint32_t thread_of_entry[CONTENDED_THREADS];
  uint32_t thread;
  bool ordered = true, owners = true;

  cmux_trace_tracer_init(&tracer, &ring, CMUX_TRACE_CAT_BLACKBOX);
  for (thread = 0; thread < CONTENDED_THREADS; thread++) {
    jobs[thread].tracer = &tracer;
    jobs[thread].thread = thread;
    jobs[thread].ready = &ready;
    CHECK(pthread_create(&threads[thread], NULL, contended_writer, &jobs[thread]) == 0);
  }
  for (thread = 0; thread < CONTENDED_THREADS; thread++) pthread_join(threads[thread], NULL);
  CHECK_EQ_U64(cmux_trace_ring_counter(&ring, CMUX_TRACE_OFF_RECORDS_DROPPED), 0);
  CHECK_EQ_U64(cmux_trace_ring_counter(&ring, CMUX_TRACE_OFF_THREAD_CURSOR), CONTENDED_THREADS);

  for (thread = 0; thread < CONTENDED_THREADS; thread++) thread_of_entry[thread] = UINT32_MAX;
  count = decode_ring(ring.base, decoded, capacity);
  CHECK_EQ_U64(count, (uint64_t)CONTENDED_THREADS * CONTENDED_RECORDS);
  /* Chunks are claimed in cursor order by each thread, so chunk order then slot order is each
   * thread's program order; every record of a chunk is its owner's. */
  for (index = 0; index < count && index < capacity; index++) {
    uint32_t writer = (uint32_t)decoded[index].arg0;
    if (writer >= CONTENDED_THREADS) {
      owners = false;
      continue;
    }
    if (thread_of_entry[writer] == UINT32_MAX) thread_of_entry[writer] = decoded[index].thread;
    if (thread_of_entry[writer] != decoded[index].thread) owners = false;
    if (decoded[index].arg1 != next[writer]) ordered = false;
    next[writer] = decoded[index].arg1 + 1;
  }
  CHECK(owners);
  CHECK(ordered);
  for (thread = 0; thread < CONTENDED_THREADS; thread++) CHECK_EQ_U64(next[thread], CONTENDED_RECORDS);
  test_release(decoded);
  test_release(next);
  test_release(ring.base);
}

/* ---- Overwrite: after 10x the capacity only whole records decode, and they are the newest. -- */

static void test_overwrite(void) {
  cmux_trace_ring ring = test_ring(8, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_tracer tracer;
  cmux_trace_writer writer;
  cmux_trace_thread_identity identity = cmux_trace_thread_identity_make(7, 0, "w");
  decoded_record decoded[8 * 31];
  uint64_t total = 10 * 8 * 31, index, lowest = UINT64_MAX;
  size_t count, at;
  cmux_trace_tracer_init(&tracer, &ring, CMUX_TRACE_CAT_BLACKBOX);
  cmux_trace_writer_init(&writer, &identity);
  for (index = 0; index < total; index++) {
    cmux_trace_record record = make_record(index + 1, 1, CMUX_TRACE_PHASE_INSTANT, 0, index, ~index);
    cmux_trace_write(&tracer, &writer, &record);
  }
  cmux_trace_writer_exit(&tracer, &writer);
  count = decode_ring(ring.base, decoded, 8 * 31);
  CHECK_EQ_U64(count, 8 * 31);
  for (at = 0; at < count; at++) {
    CHECK(decoded[at].arg1 == ~decoded[at].arg0);
    CHECK(decoded[at].t_ns == decoded[at].arg0 + 1);
    if (decoded[at].arg0 < lowest) lowest = decoded[at].arg0;
  }
  CHECK_EQ_U64(lowest, total - 8 * 31);
  CHECK(cmux_trace_ring_counter(&ring, CMUX_TRACE_OFF_CHUNKS_OVERWRITTEN) >= 9 * 8 - 1);
  test_release(ring.base);
}

/* ---- Torn writes: a writer stopped inside a record keeps its chunk; the record never decodes. -- */

static void test_torn(void) {
  cmux_trace_ring ring = test_ring(4, CMUX_TRACE_RING_BLACK_BOX);
  decoded_record decoded[4 * 31];
  uint32_t held, chunk, round;
  uint64_t lap, other_lap;
  size_t slot_at;
  cmux_trace_record record = make_record(5, 1, CMUX_TRACE_PHASE_INSTANT, 0, 6, 7);
  CHECK(cmux_trace_ring_claim(&ring, 0, 0, &held, &lap));
  /* Stop "inside" slot 1: the odd seq is stored, the payload half written. */
  slot_at = ring.layout.chunks_offset + (size_t)held * CMUX_TRACE_CHUNK_BYTES + CMUX_TRACE_RECORD_BYTES;
  cmux_trace__st32(ring.base + slot_at + CMUX_TRACE_OFF_R_SEQ, (uint32_t)cmux_trace_lap_owned(lap),
                   CMUX_TRACE__RELAXED);
  cmux_trace__st64(ring.base + slot_at + CMUX_TRACE_OFF_R_T_NS, 99, CMUX_TRACE__RELAXED);
  for (round = 0; round < 1000; round++) {
    bool claimed = cmux_trace_ring_claim(&ring, 1, 0, &chunk, &other_lap);
    CHECK(claimed);
    if (!claimed) break;
    CHECK(chunk != held);
    cmux_trace_ring_complete(&ring, chunk, other_lap);
  }
  CHECK(cmux_trace_ring_counter(&ring, CMUX_TRACE_OFF_CHUNKS_SKIPPED) >= 250);
  /* An owned chunk decodes nothing of its torn slot even when the chunk is read as complete. */
  {
    cmux_trace_ring copy = cmux_trace_ring_on(test_zeroed(ring.layout.total_bytes), ring.layout);
    size_t count, index;
    bool torn_seen = false;
    cmux_trace_ring_copy(&ring, &copy);
    count = decode_ring(copy.base, decoded, 4 * 31);
    for (index = 0; index < count && index < 4 * 31; index++) torn_seen |= decoded[index].t_ns == 99;
    CHECK(!torn_seen);
    test_release(copy.base);
  }
  cmux_trace_ring_publish(&ring, held, lap, 1, &record);
  CHECK_EQ_U64(u32_at(ring.base, slot_at + CMUX_TRACE_OFF_R_SEQ), (uint32_t)cmux_trace_lap_complete(lap));
  /* Four owned chunks: a fifth claimer drops its record. */
  {
    cmux_trace_ring small = test_ring(4, CMUX_TRACE_RING_BLACK_BOX);
    uint32_t thread;
    for (thread = 0; thread < 4; thread++) CHECK(cmux_trace_ring_claim(&small, thread, 0, &chunk, &other_lap));
    CHECK(!cmux_trace_ring_claim(&small, 9, 0, &chunk, &other_lap));
    CHECK_EQ_U64(cmux_trace_ring_counter(&small, CMUX_TRACE_OFF_RECORDS_DROPPED), 1);
    CHECK_EQ_U64(cmux_trace_ring_counter(&small, CMUX_TRACE_OFF_CHUNKS_SKIPPED), 4);
    test_release(small.base);
  }
  test_release(ring.base);
}

/* ---- Thread entries: an exited entry is taken again with the next generation. ------------- */

static void test_thread_reuse(void) {
  cmux_trace_ring ring = test_ring(4, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_thread_identity identity = cmux_trace_thread_identity_make(7, 0, "a");
  uint32_t index = 0, generation = 0, round;
  for (round = 0; round < 256; round++) cmux_trace_ring_register_thread(&ring, &identity, &index, &generation);
  CHECK_EQ_U64(index, 255);
  cmux_trace_ring_register_thread(&ring, &identity, &index, &generation);
  CHECK_EQ_U64(index, CMUX_TRACE_THREAD_NONE);
  cmux_trace_ring_exit_thread(&ring, 17);
  cmux_trace_ring_register_thread(&ring, &identity, &index, &generation);
  CHECK_EQ_U64(index, 17);
  CHECK_EQ_U64(generation, 1);
  cmux_trace_ring_exit_thread(&ring, 17);
  cmux_trace_ring_register_thread(&ring, &identity, &index, &generation);
  CHECK_EQ_U64(generation, 2);
  CHECK_EQ_U64(cmux_trace_ring_counter(&ring, CMUX_TRACE_OFF_THREAD_OVERFLOW), 1);
  test_release(ring.base);
}

/* ---- Interning: one id per text and category (ring.rs, interning_a_text_again_returns_its_entry). */

static void test_intern_once_per_text(void) {
  cmux_trace_ring ring = test_ring(4, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_tracer tracer;
  cmux_trace_writer writer;
  cmux_trace_thread_identity identity = cmux_trace_thread_identity_make(9, 0, "io");
  /* An async begin and its end at two sites: two statics of one text pair by name id. */
  cmux_trace_interned_name begin_site = {"daemon.url_open", 6, 0}, end_site = {"daemon.url_open", 6, 0};
  cmux_trace_record record = make_record(1, 0, CMUX_TRACE_PHASE_ASYNC_BEGIN, 0, 0, 7);
  decoded_record decoded[4];
  uint16_t first = cmux_trace_ring_intern(&ring, "daemon.url_open", 6), other;
  CHECK(first != 0);
  CHECK_EQ_U64(cmux_trace_ring_intern(&ring, "daemon.url_open", 6), first);
  other = cmux_trace_ring_intern(&ring, "daemon.url_open.slow", 6);
  CHECK(other != 0 && other != first);
  CHECK(cmux_trace_ring_intern(&ring, "daemon.url_open", 7) != first); /* the category is part of the name */
  CHECK_EQ_U64(cmux_trace_ring_intern(&ring, "daemon.url_open.slow", 6), other);
  CHECK(cmux_trace_ring_intern(&ring, "key.frame", 1) != 1); /* a catalog entry is not an interned one */
  CHECK_EQ_U64(cmux_trace__ld32_at(&ring, CMUX_TRACE_OFF_NAME_CURSOR, CMUX_TRACE__RELAXED), (uint64_t)other + 3);

  cmux_trace_tracer_init(&tracer, &ring, CMUX_TRACE_CAT_BLACKBOX);
  cmux_trace_writer_init(&writer, &identity);
  cmux_trace_write_named(&tracer, &writer, &record, &begin_site);
  record = make_record(2, 0, CMUX_TRACE_PHASE_ASYNC_END, 0, 0, 7);
  cmux_trace_write_named(&tracer, &writer, &record, &end_site);
  cmux_trace_writer_exit(&tracer, &writer);
  CHECK_EQ_U64(decode_ring(ring.base, decoded, 4), 2);
  CHECK_EQ_U64(decoded[0].name, first);
  CHECK_EQ_U64(decoded[1].name, first);
  test_release(ring.base);
}

/* ---- Heap then file, and recordings. ----------------------------------------------------- */

static void test_adopt_and_record(void) {
  cmux_trace_ring heap = test_ring(8, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_ring file = cmux_trace_ring_on(test_zeroed(heap.layout.total_bytes), heap.layout);
  cmux_trace_ring recording = test_ring(16, CMUX_TRACE_RING_RECORDING);
  cmux_trace_ring wrong = cmux_trace_ring_on(test_zeroed(recording.layout.total_bytes), recording.layout);
  cmux_trace_tracer tracer;
  cmux_trace_writer writer;
  cmux_trace_thread_identity identity = cmux_trace_thread_identity_make(9, 0, "host-main");
  cmux_trace_interned_name pump = {"cef.pump.work", 4, 0};
  decoded_record decoded[16 * 31];
  const uint8_t boot[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
  uint64_t index;
  size_t count, at;
  bool found;

  cmux_trace_tracer_init(&tracer, &heap, CMUX_TRACE_CAT_BLACKBOX);
  cmux_trace_writer_init(&writer, &identity);
  CHECK(cmux_trace_enabled(&tracer, CMUX_TRACE_CAT_CEF));
  CHECK(!cmux_trace_enabled(&tracer, CMUX_TRACE_CAT_FRAME));
  for (index = 0; index < 5; index++) {
    cmux_trace_record record = make_record(10 + index, 1, CMUX_TRACE_PHASE_INSTANT, 0, index, 0);
    cmux_trace_write(&tracer, &writer, &record);
  }
  CHECK_EQ_U64(cmux_trace_tracer_adopt(&tracer, &wrong, 1, boot), CMUX_TRACE_ERROR_LAYOUT_MISMATCH);
  CHECK_EQ_U64(cmux_trace_tracer_adopt(&tracer, &file, 77, boot), CMUX_TRACE_OK);
  CHECK_EQ_U64(cmux_trace_tracer_adopt(&tracer, &file, 77, boot), CMUX_TRACE_ERROR_ALREADY_ATTACHED);
  CHECK(cmux_trace_tracer_active_ring(&tracer)->base == file.base);
  CHECK_EQ_U64(u64_at(file.base, CMUX_TRACE_OFF_PROCESS_START_UNIX_US), 77);
  CHECK_EQ_U64(file.base[CMUX_TRACE_OFF_BOOT_SESSION_UUID + 15], 16);
  CHECK_EQ_U64(u64_at(file.base, CMUX_TRACE_OFF_HEAP_CURSOR), 1);
  CHECK_EQ_U64(u64_at(file.base, CMUX_TRACE_OFF_CHUNK_CURSOR), 1 + 8);
  /* The heap chunk the writer owned is copied complete; the next record goes to the file. */
  {
    cmux_trace_record record = make_record(20, 1, CMUX_TRACE_PHASE_INSTANT, 0, 5, 0);
    cmux_trace_write(&tracer, &writer, &record);
  }
  count = decode_ring(file.base, decoded, 16 * 31);
  CHECK_EQ_U64(count, 6);
  CHECK_EQ_U64(decode_ring(heap.base, decoded, 16 * 31), 5);

  /* A recording: no ring yet, then one; it records the frame category and only its own records. */
  CHECK_EQ_U64(cmux_trace_tracer_start_recording(&tracer, CMUX_TRACE_CAT_FRAME, 100, 0, 0),
               CMUX_TRACE_ERROR_NO_RECORDING_RING);
  CHECK_EQ_U64(cmux_trace_tracer_stop(&tracer), CMUX_TRACE_ERROR_NOT_RECORDING);
  CHECK_EQ_U64(cmux_trace_tracer_attach_recording(&tracer, &recording), CMUX_TRACE_OK);
  CHECK_EQ_U64(cmux_trace_tracer_attach_recording(&tracer, &recording), CMUX_TRACE_ERROR_ALREADY_ATTACHED);
  CHECK_EQ_U64(cmux_trace_tracer_start_recording(&tracer, CMUX_TRACE_CAT_FRAME, 100, 0, 0), CMUX_TRACE_OK);
  CHECK_EQ_U64(cmux_trace_tracer_start_recording(&tracer, CMUX_TRACE_CAT_FRAME, 100, 0, 0),
               CMUX_TRACE_ERROR_ALREADY_RECORDING);
  CHECK(cmux_trace_enabled(&tracer, CMUX_TRACE_CAT_FRAME));
  CHECK_EQ_U64(u64_at(file.base, CMUX_TRACE_OFF_CATEGORIES), CMUX_TRACE_CAT_BLACKBOX | CMUX_TRACE_CAT_FRAME);
  for (index = 0; index < 40; index++) {
    cmux_trace_record record = make_record(100 + index, 1, CMUX_TRACE_PHASE_INSTANT, 0, 1000 + index, 0);
    cmux_trace_write(&tracer, &writer, &record);
  }
  {
    cmux_trace_record record = make_record(150, 0, CMUX_TRACE_PHASE_BEGIN, 0, 0, 0);
    cmux_trace_write_named(&tracer, &writer, &record, &pump);
  }
  CHECK_EQ_U64(pump.ids >> 32 & 0xffff, 4);
  CHECK_EQ_U64(cmux_trace_tracer_stop(&tracer), CMUX_TRACE_OK);
  CHECK(!cmux_trace_enabled(&tracer, CMUX_TRACE_CAT_FRAME));
  CHECK(cmux_trace_tracer_active_ring(&tracer)->base == file.base);
  count = decode_ring(recording.base, decoded, 16 * 31);
  CHECK_EQ_U64(count, 41);
  CHECK_EQ_U64(decode_ring(file.base, decoded, 16 * 31), 6);

  /* A second recording starts a lap past the first: the first's records no longer decode. */
  CHECK_EQ_U64(cmux_trace_tracer_start_recording(&tracer, CMUX_TRACE_CAT_FRAME, 500, 0, 0), CMUX_TRACE_OK);
  {
    cmux_trace_record record = make_record(600, 1, CMUX_TRACE_PHASE_INSTANT, 0, 4242, 0);
    cmux_trace_write(&tracer, &writer, &record);
  }
  cmux_trace_writer_exit(&tracer, &writer);
  CHECK_EQ_U64(cmux_trace_tracer_stop(&tracer), CMUX_TRACE_OK);
  count = decode_ring(recording.base, decoded, 16 * 31);
  found = false;
  for (at = 0; at < count && at < 16 * 31; at++) found |= decoded[at].arg0 == 4242;
  CHECK_EQ_U64(count, 1);
  CHECK(found);
  CHECK_EQ_U64(u64_at(recording.base, CMUX_TRACE_OFF_START_UPTIME_NS), 500);

  test_release(heap.base);
  test_release(file.base);
  test_release(recording.base);
  test_release(wrong.base);
}

/* ---- A trace point on the real clock and thread. ----------------------------------------- */

static void test_trace_point(void) {
#if defined(CMUX_TRACE_HAS_CLOCK)
  cmux_trace_ring ring = test_ring(4, CMUX_TRACE_RING_BLACK_BOX);
  cmux_trace_tracer tracer;
  cmux_trace_writer writer;
  decoded_record decoded[4];
  uint64_t before = cmux_trace_now_ns(), after;
  cmux_trace_tracer_init(&tracer, &ring, CMUX_TRACE_CAT_BLACKBOX);
  cmux_trace_writer_init(&writer, NULL);
  cmux_trace_point(&tracer, &writer, CMUX_TRACE_CAT_CEF, 1, CMUX_TRACE_PHASE_INSTANT, 0, 1, 2);
  cmux_trace_point(&tracer, &writer, CMUX_TRACE_CAT_FRAME, 1, CMUX_TRACE_PHASE_INSTANT, 0, 3, 4);
  after = cmux_trace_now_ns();
  cmux_trace_writer_exit(&tracer, &writer);
  CHECK_EQ_U64(decode_ring(ring.base, decoded, 4), 1);
  CHECK(decoded[0].t_ns >= before && decoded[0].t_ns <= after);
  CHECK(cmux_trace_unix_ns() > UINT64_C(1600000000000000000));
#if defined(CMUX_TRACE_HAS_CURRENT_THREAD)
  {
    size_t entry = ring.layout.thread_table_offset;
    CHECK(u64_at(ring.base, entry + CMUX_TRACE_OFF_T_TID) != 0);
  }
#endif
  test_release(ring.base);
#endif
}

/* ---- Crash keys. ------------------------------------------------------------------------- */

typedef struct slot_row {
  const char *swift;
  uint32_t word;
} slot_row;

static const slot_row crash_key_slots[] = {
    {"actionIndex", CMUX_CRASH_KEY_ACTION_INDEX},
    {"actionEntrypoint", CMUX_CRASH_KEY_ACTION_ENTRYPOINT},
    {"mainTaskOwner", CMUX_CRASH_KEY_MAIN_TASK_OWNER},
    {"inCEFPump", CMUX_CRASH_KEY_IN_CEF_PUMP},
    {"lastInputUptime", CMUX_CRASH_KEY_LAST_INPUT_UPTIME},
    {"windowCount", CMUX_CRASH_KEY_WINDOW_COUNT},
    {"workspaceCount", CMUX_CRASH_KEY_WORKSPACE_COUNT},
    {"terminalCount", CMUX_CRASH_KEY_TERMINAL_COUNT},
    {"chromiumBrowserCount", CMUX_CRASH_KEY_CHROMIUM_BROWSER_COUNT},
    {"webKitViewCount", CMUX_CRASH_KEY_WEBKIT_VIEW_COUNT},
    {"daemonPID", CMUX_CRASH_KEY_DAEMON_PID},
    {"daemonState", CMUX_CRASH_KEY_DAEMON_STATE},
    {"cefAPIVersion", CMUX_CRASH_KEY_CEF_API_VERSION},
    {"ghosttyCommit", CMUX_CRASH_KEY_GHOSTTY_COMMIT},
    {"hangInProgressStart", CMUX_CRASH_KEY_HANG_IN_PROGRESS_START},
    {"hangInProgressFrameCount", CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAME_COUNT},
    {"hangInProgressImages", CMUX_CRASH_KEY_HANG_IN_PROGRESS_IMAGES},
    {"hangInProgressFrames", CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAMES},
};

/* Every `case name = N` of CrashKeySlot.swift has the same word here, and no slot is missing. */
static void test_crash_key_slots_match_swift(const char *swift_path) {
  size_t length = 0, rows = sizeof crash_key_slots / sizeof crash_key_slots[0], matched = 0, index;
  uint8_t *source = read_file(swift_path, &length);
  char *line;
  CHECK(source != NULL);
  if (!source) return;
  for (line = (char *)source; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
    char name[64];
    unsigned word = 0;
    if (sscanf(line, " case %63[A-Za-z] = %u", name, &word) != 2) continue;
    for (index = 0; index < rows; index++) {
      if (strcmp(crash_key_slots[index].swift, name) == 0) break;
    }
    if (index == rows) {
      fprintf(stderr, "CrashKeySlot.%s = %u has no CMUX_CRASH_KEY_ define in cmux_trace.h\n", name, word);
      failures++;
      continue;
    }
    CHECK_EQ_U64(crash_key_slots[index].word, word);
    matched++;
  }
  CHECK_EQ_U64(matched, rows);
  CHECK(strstr((char *)source, "pageWordCount = 512") != NULL);
  CHECK(strstr((char *)source, "headerWordCount = 8") != NULL);
  CHECK(strstr((char *)source, "case .hangInProgressImages: 32") != NULL);
  CHECK(strstr((char *)source, "case .hangInProgressFrames: 64") != NULL);
  test_release(source);
}

/* `text` with each run of whitespace as one space, in `out` (NUL terminated, cut at `size`). */
static void squeeze_spaces(const char *text, size_t length, char *out, size_t size) {
  size_t used = 0, index;
  bool space = false;
  for (index = 0; index < length && used + 2 < size; index++) {
    char c = text[index];
    if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
      space = used > 0;
      continue;
    }
    if (space) out[used++] = ' ';
    space = false;
    out[used++] = c;
  }
  out[used] = '\0';
}

/* The number right after `prefix` in `source` (hex after 0x, `_` separators allowed); false when absent. */
static bool swift_number_after(const char *source, const char *prefix, uint64_t *value) {
  const char *at = strstr(source, prefix);
  unsigned base = 10;
  bool any = false;
  *value = 0;
  if (!at) return false;
  at += strlen(prefix);
  if (at[0] == '0' && at[1] == 'x') {
    base = 16;
    at += 2;
  }
  for (;; at++) {
    unsigned digit;
    if (*at == '_') continue;
    if (*at >= '0' && *at <= '9') {
      digit = (unsigned)(*at - '0');
    } else if (base == 16 && *at >= 'A' && *at <= 'F') {
      digit = (unsigned)(*at - 'A' + 10);
    } else if (base == 16 && *at >= 'a' && *at <= 'f') {
      digit = (unsigned)(*at - 'a' + 10);
    } else {
      break;
    }
    *value = *value * base + digit;
    any = true;
  }
  return any;
}

/* CrashKeyPage.header in CrashKeys.swift writes the words cmux_crash_keys_init writes: the same
 * magic, version and page size, and the same word order. A change to either header fails here. */
static void test_crash_keys_header_matches_swift(const char *swift_path) {
  size_t length = 0, index;
  uint8_t *source = read_file(swift_path, &length);
  const char *text = (const char *)source, *body, *list, *end;
  char words[512];
  uint64_t magic = 0, swift_magic = 0, version = 0, page_words = 0;
  CHECK(source != NULL);
  if (!source) return;
  for (index = 0; index < 8; index++) magic |= (uint64_t)(uint8_t)CMUX_CRASH_KEYS_MAGIC[index] << (8 * index);
  CHECK(swift_number_after(text, "static var magic: UInt64 { ", &swift_magic));
  CHECK_EQ_U64(swift_magic, magic);
  CHECK(swift_number_after(text, "static var version: UInt64 { ", &version));
  CHECK_EQ_U64(version, CMUX_CRASH_KEYS_VERSION);
  CHECK(swift_number_after(text, "static var wordCount: Int { ", &page_words));
  CHECK_EQ_U64(page_words, CMUX_CRASH_KEYS_PAGE_WORDS);
  body = strstr(text, "static func header(_ identity: Identity) -> [UInt64] {");
  CHECK(body != NULL);
  if (body) {
    CHECK(strstr(body, "let low = uuid.prefix(8)") != NULL);
    CHECK(strstr(body, "let high = uuid.dropFirst(8)") != NULL);
    list = strstr(body, "return [");
    end = list ? strchr(list, ']') : NULL;
    CHECK(end != NULL);
    if (list && end) {
      list += strlen("return [");
      squeeze_spaces(list, (size_t)(end - list), words, sizeof words);
      /* Word for word what cmux_crash_keys_init stores at words 0-7. */
      if (strcmp(words, "magic, version | UInt64(CrashKeySlot.headerWordCount) << 16 | UInt64(wordCount) << 32, "
                        "UInt64(identity.pid) | UInt64(identity.role.rawValue) << 32, low, high, "
                        "identity.processStartUnixMicros, identity.startUptimeNanos, 0,") != 0) {
        fprintf(stderr, "CrashKeyPage.header is not the header cmux_crash_keys_init writes: %s\n", words);
        failures++;
      }
    }
  }
  test_release(source);
}

/* The page cmux_crash_keys_init and three keys make: the shared fixture's bytes, which CrashKeysTests
 * decodes with CrashKeyPage.decode and compares with the page the Swift writer makes. */
static void crash_keys_fixture_page(uint8_t *page) {
  const uint8_t uuid[16] = {0xA0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0xAF};
  cmux_crash_keys keys =
      cmux_crash_keys_init(page, CMUX_TRACE_ROLE_CHROMIUM_HOST, 321, UINT64_C(1700000000000000), uuid, 66);
  cmux_crash_keys_set(keys, CMUX_CRASH_KEY_IN_CEF_PUMP, 1);
  cmux_crash_keys_set(keys, CMUX_CRASH_KEY_DAEMON_PID, 777);
  cmux_crash_keys_set(keys, CMUX_CRASH_KEY_GHOSTTY_COMMIT, UINT64_C(0xABCDEF0123456789));
}

static void test_crash_keys_fixture(const char *fixture_path) {
  size_t length = 0;
  uint8_t *fixture = read_file(fixture_path, &length);
  uint8_t *page = (uint8_t *)test_zeroed(CMUX_CRASH_KEYS_PAGE_BYTES);
  crash_keys_fixture_page(page);
  CHECK(fixture != NULL);
  CHECK_EQ_U64(length, CMUX_CRASH_KEYS_PAGE_BYTES);
  if (fixture && length == CMUX_CRASH_KEYS_PAGE_BYTES) CHECK(memcmp(page, fixture, CMUX_CRASH_KEYS_PAGE_BYTES) == 0);
  if (fixture) test_release(fixture);
  test_release(page);
}

static void test_crash_keys(void) {
  uint8_t *page = (uint8_t *)test_zeroed(CMUX_CRASH_KEYS_PAGE_BYTES);
  const uint8_t uuid[16] = {0xA0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0xAF};
  cmux_crash_keys keys = cmux_crash_keys_init(page, CMUX_TRACE_ROLE_CHROMIUM_HOST, 321, 55, uuid, 66);
  CHECK(memcmp(page, "CMXKEYS1", 8) == 0);
  CHECK_EQ_U64(u64_at(page, 8), 1 | UINT64_C(8) << 16 | UINT64_C(512) << 32);
  CHECK_EQ_U64(u64_at(page, 16), 321 | (uint64_t)CMUX_TRACE_ROLE_CHROMIUM_HOST << 32);
  CHECK_EQ_U64(page[24], 0xA0);
  CHECK_EQ_U64(page[39], 0xAF);
  CHECK_EQ_U64(u64_at(page, 40), 55);
  CHECK_EQ_U64(u64_at(page, 48), 66);
  CHECK_EQ_U64(u64_at(page, 56), 0);
  CHECK(cmux_crash_keys_set(keys, CMUX_CRASH_KEY_IN_CEF_PUMP, 1));
  CHECK_EQ_U64(u64_at(page, 8 * CMUX_CRASH_KEY_IN_CEF_PUMP), 1);
  CHECK_EQ_U64(cmux_crash_keys_get(keys, CMUX_CRASH_KEY_IN_CEF_PUMP), 1);
  CHECK(cmux_crash_keys_set_word(keys, CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAMES, 63, 0xBEEF));
  CHECK_EQ_U64(u64_at(page, 8 * (56 + 63)), 0xBEEF);
  CHECK(!cmux_crash_keys_set(keys, 3, 9)); /* the header */
  CHECK(!cmux_crash_keys_set_word(keys, CMUX_CRASH_KEY_HANG_IN_PROGRESS_FRAMES, 512, 9));
  CHECK(!cmux_crash_keys_set(keys, 512, 9));
  CHECK_EQ_U64(u64_at(page, 40), 55);
  CHECK_EQ_U64(cmux_crash_keys_get(keys, 600), 0);
  test_release(page);
}

/* ---- The shared numbers (trace.md tables; tests/shared_values.rs pins the same). ---------- */

static void test_shared_values(void) {
  unsigned bit;
  const uint64_t bits[20] = {
      CMUX_TRACE_CAT_ACTION, CMUX_TRACE_CAT_KEY,    CMUX_TRACE_CAT_SWITCH,  CMUX_TRACE_CAT_CREATE,
      CMUX_TRACE_CAT_CEF,    CMUX_TRACE_CAT_LAUNCH, CMUX_TRACE_CAT_DAEMON,  CMUX_TRACE_CAT_HANG,
      CMUX_TRACE_CAT_CRASH,  CMUX_TRACE_CAT_MOTION, CMUX_TRACE_CAT_FRAME,   CMUX_TRACE_CAT_STALL,
      CMUX_TRACE_CAT_TASK,   CMUX_TRACE_CAT_BURST,  CMUX_TRACE_CAT_INPUT,   CMUX_TRACE_CAT_WEBVIEW,
      CMUX_TRACE_CAT_REMOTE, CMUX_TRACE_CAT_CONTROL, CMUX_TRACE_CAT_GHOSTTY, CMUX_TRACE_CAT_RESIZE,
  };
  for (bit = 0; bit < 20; bit++) CHECK_EQ_U64(bits[bit], UINT64_C(1) << bit);
  CHECK_EQ_U64(CMUX_TRACE_CAT_ALL, (UINT64_C(1) << 20) - 1);
  CHECK_EQ_U64(CMUX_TRACE_CAT_BLACKBOX & CMUX_TRACE_CAT_RECORDING, 0);
  CHECK_EQ_U64(CMUX_TRACE_PHASE_BEGIN, 'B');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_END, 'E');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_INSTANT, 'I');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_ASYNC_BEGIN, 'b');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_ASYNC_END, 'e');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_FLOW_OUT, 's');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_FLOW_IN, 'f');
  CHECK_EQ_U64(CMUX_TRACE_PHASE_COUNTER, 'C');
  CHECK_EQ_U64(CMUX_TRACE_ROLE_APP, 1);
  CHECK_EQ_U64(CMUX_TRACE_ROLE_CHROMIUM_HOST, 6);
  CHECK_EQ_U64(CMUX_TRACE_ROLE_CLI, 7);
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: %s GOLDEN_FILE CRASH_KEY_SLOT_SWIFT CRASH_KEYS_SWIFT CRASH_KEYS_FIXTURE\n", argv[0]);
    return 2;
  }
  test_shared_values();
  test_offsets();
  test_golden(argv[1]);
  test_torn();
  test_thread_reuse();
  test_intern_once_per_text();
  test_overwrite();
  test_adopt_and_record();
  test_trace_point();
  test_crash_keys();
  test_crash_key_slots_match_swift(argv[2]);
  test_crash_keys_header_matches_swift(argv[3]);
  test_crash_keys_fixture(argv[4]);
  test_contended();
  if (failures) {
    fprintf(stderr, "cmux_trace_test: %d failure(s)\n", failures);
    return 1;
  }
  printf("cmux_trace_test: ok\n");
  return 0;
}
