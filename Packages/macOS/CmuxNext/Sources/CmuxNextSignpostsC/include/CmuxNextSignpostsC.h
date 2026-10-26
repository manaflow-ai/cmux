#ifndef CMUX_NEXT_SIGNPOSTS_C_H_
#define CMUX_NEXT_SIGNPOSTS_C_H_
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// The per-key signposts, with no heap allocation (p09-observability task 007).
//
// os_signpost's C macros format into a stack buffer sized at compile time
// (__builtin_os_log_format_buffer_size), as Chromium's TRACE_EVENT macros
// write typed arguments with no allocation (base/trace_event/trace_event.h).
// Swift's OSSignposter.beginInterval returns a heap OSSignpostIntervalState
// per interval, so CmuxNextSignposts' Signposter calls these for the key path.
// They emit on the `key` category of the cmux subsystem; the names and
// messages are the catalog's (SignpostName.keyToFrame, SignpostName.keyFlow).

// "com.cmuxterm.app.next" (tests compare it with SignpostCategory.subsystem).
const char *cmux_signpost_subsystem(void);
// "key" (SignpostCategory.key).
const char *cmux_signpost_key_category(void);
// "key.frame" (SignpostName.keyToFrame).
const char *cmux_signpost_key_frame_name(void);
// "key.flow" (SignpostName.keyFlow).
const char *cmux_signpost_key_flow_name(void);

// A new key.frame interval id (os_signpost_id_generate on the key log).
uint64_t cmux_signpost_key_frame_id(void);
// Begins key.frame interval `id` with `target=<view|terminal> age_ms=<age, 2 decimals>`;
// `age_ms` is -1 when the key has no timestamp.
void cmux_signpost_key_frame_begin(uint64_t id, int terminal, double age_ms);
// Ends key.frame interval `id`: no message after the turn's commit, `commit=missed`
// when the commit boundary missed it.
void cmux_signpost_key_frame_end(uint64_t id, int missed);
// One key.flow point event: `hop=<hop> flow=<flow> age_us=<age>`. `hop` is a
// static NUL-terminated name (a Swift StaticString).
void cmux_signpost_key_flow_hop(const char *hop, uint64_t flow, int64_t age_us);

#ifdef __cplusplus
}
#endif
#endif
