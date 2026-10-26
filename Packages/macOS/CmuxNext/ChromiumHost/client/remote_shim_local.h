// The local class of the remote shim (libcmux_cef_shim_remote.dylib,
// plans/cmux-next/chrome-parity/p01-process.md, task 014b): the exports that
// take a function pointer. A function pointer cannot cross a process, so the
// client keeps each callback and calls it on the main thread when the host's
// push for it arrives in an event batch, as Chrome's browser process keeps the
// RenderWidgetHostViewMac client and feeds it the renderer's pushed
// TextInputState (content/browser/renderer_host/text_input_manager.cc).
//
// remote_shim_local.mm defines cmux_shim_initialize,
// cmux_shim_post_user_input_task, cmux_shim_browser_text_input_watch,
// cmux_shim_set_drag_source_handler and cmux_shim_password_reveal; the
// generator (gen-chromium-host-wire.py) emits no marshaller for them. The
// transport (remote_shim.mm, task 014) owns the wire: it calls Attach with its
// LocalTransport when the host's hello arrives, Detach when the host is gone,
// and the Deliver* calls while it applies a batch.
//
// Main thread only, as the in-process shim (cmux_cef_shim.h, "Threading"),
// except cmux_shim_post_user_input_task, which touches no state. No call
// waits for the host.
#pragma once

#include <cstddef>
#include <cstdint>

#include "cmux_cef_shim.h"

namespace cmux_remote {

// cmux_shim_initialize's arguments, valid only during SendInitialize.
struct InitializeRequest {
  const char* framework_dir;
  const char* main_bundle_path;
  const char* subprocess_path;
  const char* root_cache_path;
  const char* log_file;
  int log_severity;
  const char* locale;
  const char* accept_languages;
  const char* const* switches;  // NULL terminated, or NULL
};

// What the transport sends for the local class. Each call returns at once and
// never waits; false means nothing was sent.
struct LocalTransport {
  void* context;
  // One INITIALIZE op, after the queued preinit ops (task 013).
  bool (*send_initialize)(void* context, const InitializeRequest& request);
  // TEXT_INPUT_STATE pushes for browser_id start (watching) or stop.
  bool (*send_text_input_watch)(void* context, int browser_id, bool watching);
  // DRAG_START pushes start (installed) or stop; Chromium's own drag session
  // otherwise.
  bool (*send_drag_source_handler)(void* context, bool installed);
  // The reveal request; its answer is DeliverPasswordReveal with the token.
  bool (*send_password_reveal)(void* context, uint32_t token, const char* profile_cache_path, const char* id);
  // A token no other op of this connection uses.
  uint32_t (*next_token)(void* context);
};

// The page's drag handler (cmux_shim_set_drag_source_handler).
using DragSourceFn = void (*)(void* context, int browser_id, const void* drag);
// A text input watch (cmux_shim_browser_text_input_watch).
using TextInputFn = void (*)(void* context, int browser_id, const void* state);

// The host's hello arrived: sends go to `transport` (which outlives the
// matching Detach), and the drag handler state the host has not taken (set
// before it, or refused by the transport) is sent.
void Attach(const LocalTransport* transport);
// The host is gone: every pending reveal ends with done(ctx, NULL, 0), every
// text input watch ends (its browser died with the host), and a later
// cmux_shim_initialize starts the next host's Chromium.
void Detach();

// One shim event for the event_fn cmux_shim_initialize stored. False before
// initialize. NULL strings arrive as "" (the header's event_fn contract).
bool DeliverEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1, const char* s2);
// A TEXT_INPUT_STATE push: `state` is the fork's cmux_text_input_state_t that
// the transport decoded (task 044), valid during the call. False when nothing
// watches browser_id.
bool DeliverTextInputState(int browser_id, const void* state);
// A DRAG_START push: `drag` is the fork's cmux_drag_source_t that the
// transport decoded (task 051), valid during the call. False with no handler.
bool DeliverDragStart(int browser_id, const void* drag);
// The REPLY to a reveal: `password` holds `length` UTF-8 bytes from the sealed
// reply buffer (task 020), NULL when the host found none. The transport zeroes
// the buffer after this returns; nothing here copies or logs it. False for an
// unknown token (already answered or ended by Detach).
bool DeliverPasswordReveal(uint32_t token, const char* password, size_t length);

}  // namespace cmux_remote
