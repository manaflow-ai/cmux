#ifndef CMUX_NEXT_SIGNPOSTS_C_H_
#define CMUX_NEXT_SIGNPOSTS_C_H_
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// The key and stall signposts, with no heap allocation (p09-observability task 007).
//
// os_signpost's C macros format into a stack buffer sized at compile time
// (__builtin_os_log_format_buffer_size), as Chromium's TRACE_EVENT macros
// write typed arguments with no allocation (base/trace_event/trace_event.h).
// Swift's OSSignposter.beginInterval returns a heap OSSignpostIntervalState
// per interval, and the os overlay copies a small Swift String argument to
// the heap for its NUL-terminated bytes, so CmuxNextSignposts' Signposter
// calls these for the per-key and per-task signposts. They emit on the `key`
// and `stall` categories of the cmux subsystem; the names and messages are
// the catalog's (SignpostName.keyToFrame, .keyFlow, .stallMainTask,
// .stallOverBudget). A string argument is NUL-terminated and read only
// during the call. Off Apple platforms they emit nothing (signposts.c).

// "com.cmuxterm.app.next" (tests compare it with SignpostCategory.subsystem).
const char *cmux_signpost_subsystem(void);
// "key" (SignpostCategory.key).
const char *cmux_signpost_key_category(void);
// "stall" (SignpostCategory.stall).
const char *cmux_signpost_stall_category(void);
// "key.frame" (SignpostName.keyToFrame).
const char *cmux_signpost_key_frame_name(void);
// "key.flow" (SignpostName.keyFlow).
const char *cmux_signpost_key_flow_name(void);
// "stall.main_task" (SignpostName.stallMainTask).
const char *cmux_signpost_stall_task_name(void);
// "stall.over_budget" (SignpostName.stallOverBudget).
const char *cmux_signpost_stall_over_budget_name(void);

// A new key.frame interval id (os_signpost_id_generate on the key log).
uint64_t cmux_signpost_key_frame_id(void);
// Begins key.frame interval `id` with `target=<view|terminal> age_ms=<age, 2 decimals>`;
// `age_ms` is -1 when the key has no timestamp.
void cmux_signpost_key_frame_begin(uint64_t id, int terminal, double age_ms);
// Ends key.frame interval `id`: no message after the turn's commit, `commit=missed`
// when the commit boundary missed it.
void cmux_signpost_key_frame_end(uint64_t id, int missed);
// One key.flow point event: `hop=<hop> flow=<flow> age_us=<age>`.
void cmux_signpost_key_flow_hop(const char *hop, uint64_t flow, int64_t age_us);

// A new stall.main_task interval id (os_signpost_id_generate on the stall log).
uint64_t cmux_signpost_stall_task_id(void);
// Begins stall.main_task interval `id` with `class=<class> owner=<owner>`.
void cmux_signpost_stall_task_begin(uint64_t id, const char *task_class, const char *owner);
// Ends stall.main_task interval `id`.
void cmux_signpost_stall_task_end(uint64_t id);
// One stall.over_budget point event:
// `class=<class> owner=<owner> ms=<task time, 2 decimals> budget_ms=<budget, 2 decimals>`.
void cmux_signpost_stall_over_budget(const char *task_class, const char *owner, double ms, double budget_ms);

#if !defined(__APPLE__)
// A new signpost id, unique in the process. Off Apple platforms there is no
// unified log: the emitters above are no-ops, and the key, stall and
// OSSignposter ids (CmuxNextSignposts/Platform/OSSignposter+Linux.swift) all
// come from this one counter, since the trace ring keys async slices by id.
uint64_t cmux_signpost_next_id(void);
#endif

#ifdef __cplusplus
}
#endif
#endif
