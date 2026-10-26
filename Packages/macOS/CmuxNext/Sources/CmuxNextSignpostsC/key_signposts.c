#include "CmuxNextSignpostsC.h"

#include <dispatch/dispatch.h>
#include <os/log.h>
#include <os/signpost.h>

#define SUBSYSTEM "com.cmuxterm.app.next"
#define KEY_CATEGORY "key"
// os_signpost names and formats must be string literals: the macros pass
// their addresses in the binary.
#define KEY_FRAME_NAME "key.frame"
#define KEY_FLOW_NAME "key.flow"

static os_log_t key_log;
static dispatch_once_t key_log_once;

static void make_key_log(void *context) {
  (void)context;
  key_log = os_log_create(SUBSYSTEM, KEY_CATEGORY);
}

// The key category's log, made once (os_log_create allocates; later calls only load it).
static os_log_t key(void) {
  dispatch_once_f(&key_log_once, NULL, make_key_log);
  return key_log;
}

const char *cmux_signpost_subsystem(void) { return SUBSYSTEM; }

const char *cmux_signpost_key_category(void) { return KEY_CATEGORY; }

const char *cmux_signpost_key_frame_name(void) { return KEY_FRAME_NAME; }

const char *cmux_signpost_key_flow_name(void) { return KEY_FLOW_NAME; }

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
