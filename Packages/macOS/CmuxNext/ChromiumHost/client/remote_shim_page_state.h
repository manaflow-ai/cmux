// The remote shim's page state exports (task p01-process-093):
// cmux_shim_tab_page_state_watch and cmux_shim_tab_entry_page_state. A
// function pointer cannot cross a process, so the client keeps cmux's fn per
// browser; the host watches the fork for that browser and pushes each changed
// entry's page state at idle (CMUX_SHIM_PAGE_STATE, HOST/src/host_page_state.h).
// The client keeps the last state of each pushed entry, so the read cmux makes
// in its fn, as it makes it in process, answers with no call to the host, as
// Chrome's browser process keeps each NavigationEntry's PageState that the
// renderer sends (content/browser/renderer_host/navigation_entry_impl.h).
//
// remote_shim.mm hands the pushes to Deliver, every BEFORE_CLOSE to
// BrowserClosed, calls Attach at the host's HELLO and Detach when it is gone.
// Plain C++ (no Objective-C): tests/remote_shim_page_state_test.cpp compiles it
// on any machine. Main thread only, as the in-process shim.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include "cmux_cef_shim.h"

namespace cmux_remote::page_state {

// What the module sends: one call, never waiting; false means nothing went.
struct Transport {
  void* context;
  // kOpTabPageStateWatch: i32 browser, i32 watching.
  bool (*send_watch)(void* context, int browser_id, bool watching);
};

// cmux's watch (cmux_shim_tab_page_state_watch).
using WatchFn = void (*)(void* context, int browser_id, int index);

// The host's HELLO came: watches go to `transport`, which outlives the
// matching Detach.
void Attach(const Transport* transport);
// The host is gone with its browsers: every watch and kept state ends.
void Detach();

// Whether `kind` is the push this module takes instead of cmux's event fn.
inline bool IsPushEvent(int kind) { return kind == CMUX_SHIM_PAGE_STATE; }
// A CMUX_SHIM_PAGE_STATE push: entry `index` of `browser_id` has `state`
// when `has_state`, else none. Kept for a watched browser, then its fn runs.
// False when nothing watches the browser or the index is out of range.
bool Deliver(int browser_id, int index, bool has_state, const std::string& state);
// The browser closed: its watch and states end.
void BrowserClosed(int browser_id);

// The kept states of every watched browser (tests).
size_t KeptStates();

}  // namespace cmux_remote::page_state
