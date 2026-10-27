#include "CmuxNextSignpostsC.h"

#include <stddef.h>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <os/signpost.h>
#else
#include <stdatomic.h>
#endif

#define SUBSYSTEM "com.cmuxterm.app.next"
#define KEY_CATEGORY "key"
#define STALL_CATEGORY "stall"
// os_signpost names and formats must be string literals: the macros pass
// their addresses in the binary.
#define KEY_FRAME_NAME "key.frame"
#define KEY_FLOW_NAME "key.flow"
#define STALL_TASK_NAME "stall.main_task"
#define STALL_OVER_BUDGET_NAME "stall.over_budget"

const char *cmux_signpost_subsystem(void) { return SUBSYSTEM; }

const char *cmux_signpost_key_category(void) { return KEY_CATEGORY; }

const char *cmux_signpost_stall_category(void) { return STALL_CATEGORY; }

const char *cmux_signpost_key_frame_name(void) { return KEY_FRAME_NAME; }

const char *cmux_signpost_key_flow_name(void) { return KEY_FLOW_NAME; }

const char *cmux_signpost_stall_task_name(void) { return STALL_TASK_NAME; }

const char *cmux_signpost_stall_over_budget_name(void) { return STALL_OVER_BUDGET_NAME; }

#if defined(__APPLE__)
static os_log_t key_log;
static dispatch_once_t key_log_once;
static os_log_t stall_log;
static dispatch_once_t stall_log_once;

static void make_key_log(void *context) {
  (void)context;
  key_log = os_log_create(SUBSYSTEM, KEY_CATEGORY);
}

static void make_stall_log(void *context) {
  (void)context;
  stall_log = os_log_create(SUBSYSTEM, STALL_CATEGORY);
}

// Each category's log, made once (os_log_create allocates; later calls only load it).
static os_log_t key(void) {
  dispatch_once_f(&key_log_once, NULL, make_key_log);
  return key_log;
}

static os_log_t stall(void) {
  dispatch_once_f(&stall_log_once, NULL, make_stall_log);
  return stall_log;
}

uint64_t cmux_signpost_key_frame_id(void) { return (uint64_t)os_signpost_id_generate(key()); }

void cmux_signpost_key_frame_begin(uint64_t id, int terminal, double age_ms) {
  os_log_t log = key();
  os_signpost_id_t interval = (os_signpost_id_t)id;
  if (terminal) {
    os_signpost_interval_begin(log, interval, KEY_FRAME_NAME, "target=terminal age_ms=%.2f", age_ms);
  } else {
    os_signpost_interval_begin(log, interval, KEY_FRAME_NAME, "target=view age_ms=%.2f", age_ms);
  }
}

void cmux_signpost_key_frame_end(uint64_t id, int missed) {
  os_log_t log = key();
  os_signpost_id_t interval = (os_signpost_id_t)id;
  if (missed) {
    os_signpost_interval_end(log, interval, KEY_FRAME_NAME, "commit=missed");
  } else {
    os_signpost_interval_end(log, interval, KEY_FRAME_NAME);
  }
}

void cmux_signpost_key_flow_hop(const char *hop, uint64_t flow, int64_t age_us) {
  os_signpost_event_emit(key(), OS_SIGNPOST_ID_EXCLUSIVE, KEY_FLOW_NAME, "hop=%{public}s flow=%llu age_us=%lld", hop,
                         (unsigned long long)flow, (long long)age_us);
}

uint64_t cmux_signpost_stall_task_id(void) { return (uint64_t)os_signpost_id_generate(stall()); }

void cmux_signpost_stall_task_begin(uint64_t id, const char *task_class, const char *owner) {
  os_signpost_interval_begin(stall(), (os_signpost_id_t)id, STALL_TASK_NAME, "class=%{public}s owner=%{public}s",
                             task_class, owner);
}

void cmux_signpost_stall_task_end(uint64_t id) {
  os_signpost_interval_end(stall(), (os_signpost_id_t)id, STALL_TASK_NAME);
}

void cmux_signpost_stall_over_budget(const char *task_class, const char *owner, double ms, double budget_ms) {
  os_signpost_event_emit(stall(), OS_SIGNPOST_ID_EXCLUSIVE, STALL_OVER_BUDGET_NAME,
                         "class=%{public}s owner=%{public}s ms=%.2f budget_ms=%.2f", task_class, owner, ms, budget_ms);
}

#else
// No unified log off Apple platforms (Platform/OSSignposter+Linux.swift in
// CmuxNextSignposts): nothing is emitted, and every id comes from one relaxed
// counter, starting above OS_SIGNPOST_ID_NULL (0), so the trace ring's async
// slices still pair.
static _Atomic uint64_t next_id = 1;

uint64_t cmux_signpost_next_id(void) { return atomic_fetch_add_explicit(&next_id, 1, memory_order_relaxed); }

uint64_t cmux_signpost_key_frame_id(void) { return cmux_signpost_next_id(); }

void cmux_signpost_key_frame_begin(uint64_t id, int terminal, double age_ms) {
  (void)id;
  (void)terminal;
  (void)age_ms;
}

void cmux_signpost_key_frame_end(uint64_t id, int missed) {
  (void)id;
  (void)missed;
}

void cmux_signpost_key_flow_hop(const char *hop, uint64_t flow, int64_t age_us) {
  (void)hop;
  (void)flow;
  (void)age_us;
}

uint64_t cmux_signpost_stall_task_id(void) { return cmux_signpost_next_id(); }

void cmux_signpost_stall_task_begin(uint64_t id, const char *task_class, const char *owner) {
  (void)id;
  (void)task_class;
  (void)owner;
}

void cmux_signpost_stall_task_end(uint64_t id) { (void)id; }

void cmux_signpost_stall_over_budget(const char *task_class, const char *owner, double ms, double budget_ms) {
  (void)task_class;
  (void)owner;
  (void)ms;
  (void)budget_ms;
}
#endif
