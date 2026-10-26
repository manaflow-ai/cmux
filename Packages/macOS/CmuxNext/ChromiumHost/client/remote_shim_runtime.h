// libcmux_cef_shim_remote.dylib: the ABI of cmux_cef_shim.h (the same cmux_shim_abi_id) for
// host mode, where Chromium's browser process is the Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md 3.2). Every export returns at once: a post
// becomes a control channel frame, a mirror read reads the main-thread cache, a mint returns an
// id cmux chose. Chrome's model is a mojo Remote (mojo/public/cpp/bindings/remote.h): calls
// never wait for the other process, and calls made before the pipe is bound are queued.
//
// The exports are generated (generated/remote_shim.inc, scripts/cmux-next/gen-chromium-host-wire.py)
// except the `local` ones: remote_shim.mm (load, prepare_application, initialize, do_work, free,
// free_owned, password_entry_size) and remote_shim_local.mm (task 014b: the exports with a
// function-pointer parameter). This header is the interface both include.
//
// Threads: every shim call is on the main thread (cmux_cef_shim.h), so the client's state is
// main-thread state with no lock; each entry asserts it. The control channel's reader thread
// (chromium_host_control.h) hands host frames to the main thread through the embedder's
// post_main, once per batch.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

#include "chromium_host_tlv.h"

#define CMUX_REMOTE_EXPORT __attribute__((visibility("default")))

extern "C" {

// Runs `task` on the main thread; the remote shim calls it from the control channel's reader
// thread. cmux passes its per-frame visible work scheduler (MainWorkScheduler, task 015). Each
// task must run exactly once.
typedef void (*cmux_remote_main_task_fn)(void* task);
typedef void (*cmux_remote_post_main_fn)(void* ctx, cmux_remote_main_task_fn run, void* task);
// Main thread. The host's HELLO arrived (its wire generation is this client's, kWireID), after
// the MIRROR values whose only refresh event is attach: CEFRuntime.start's attach await ends
// here (task 015).
typedef void (*cmux_remote_ready_fn)(void* ctx);
// Main thread. A REPLY frame for a token the client sent with PostForReply or a non-void
// PostPreinit (an async op answered by wire:REPLY, a preinit's verdict): its fields, encoded as
// cmux_host::control::EncodeFields. Task 018's waiter resumes the caller from it.
typedef void (*cmux_remote_reply_fn)(void* ctx, uint32_t token, const void* fields, size_t length);
// Main thread. The control channel ended (a cmux_remote_end_reason) and the shim detached: every
// token still awaiting a reply went with the host (task 091 resolves them as hostGone).
typedef void (*cmux_remote_ended_fn)(void* ctx, int reason);

typedef enum {
  CMUX_REMOTE_END_CLOSED = 0,       // the channel closed with no reason from the host
  CMUX_REMOTE_END_PEER_CLOSED = 1,  // the host closed its end (it exited)
  CMUX_REMOTE_END_MALFORMED = 2,    // the host sent a bad frame or another wire: end the host
  CMUX_REMOTE_END_QUOTA = 3,        // the host read nothing for the quota ceiling
  CMUX_REMOTE_END_IO_ERROR = 4,
} cmux_remote_end_reason;

typedef struct {
  void* ctx;
  cmux_remote_post_main_fn post_main;  // required
  cmux_remote_ready_fn ready;          // optional
  cmux_remote_reply_fn reply;          // optional
  cmux_remote_ended_fn ended;          // optional
} cmux_remote_shim_callbacks;

typedef struct {
  uint64_t quota_excess;       // posts while the channel's outbox or the attach queue was over quota
  uint64_t coalesced;          // waiting state ops replaced by a newer one
  uint64_t pending_messages;   // frames the socket has not taken yet
  uint64_t reads_unattached;   // mirror reads with no host attached (a bug before attach)
  uint64_t unsendable;         // ops not sent: over a frame bound, or no host
  uint64_t replies_unhandled;  // REPLY frames with no reply callback
  uint64_t unsupported;        // optional ops refused: the host's HELLO did not list the export
} cmux_remote_shim_stats;

// Main thread, before the first attach; the callbacks are copied.
CMUX_REMOTE_EXPORT void cmux_remote_shim_configure(const cmux_remote_shim_callbacks* callbacks);
// Main thread. Connects the shim to a started host. `ctl_fd` is cmux's end of the control
// socket pair; the shim owns it from here. `in_ring`/`out_ring` are the input rings (task 041),
// kept for remote_shim_local.mm. Sends HELLO, the preinit replay log (PostPreinit), INITIALIZE
// when cmux_shim_initialize ran, then the ops posted before the first attach in call order; an
// optional op and the posts after it wait for the host's HELLO, which says whether the host has
// it. Returns 0 (and closes nothing) when not configured, when ctl_fd is invalid or when a host
// is attached already.
CMUX_REMOTE_EXPORT int cmux_remote_shim_attach(int ctl_fd, void* in_ring, void* out_ring);
// Main thread. Disconnects (host exit, Reload): closes the channel, drops the mirror cache, the
// pending marks, the awaited tokens and the posts still waiting for the HELLO; `ended` is not
// called. Posts fail until the next attach, which replays the preinit log (asking no verdict
// twice) and INITIALIZE to the new host. Ids and tokens keep counting.
CMUX_REMOTE_EXPORT void cmux_remote_shim_detach(void);
CMUX_REMOTE_EXPORT int cmux_remote_shim_attached(void);
// 1 when the attached host's HELLO listed `name`: an optional_exports symbol its shim defines
// (CEFForkFeatures reads this in host mode, not the remote dylib's own symbols).
CMUX_REMOTE_EXPORT int cmux_remote_shim_host_has_export(const char* name);
CMUX_REMOTE_EXPORT void cmux_remote_shim_get_stats(cmux_remote_shim_stats* out);
// Main thread. The input ring's writer (ChromiumHostInputRing, tasks 041 and 042) calls it for
// each frame it writes, in write order: returns the frame's input seq (Header::seq) and puts in
// `ctl_seq` the control seq to stamp (SetCtlSeq), that of the last ordered op posted before it.
// Ordered ops carry the returned seq as the input they follow (task 092; chromium_host_wire.h,
// "One ordered input stream"). Both seqs start again at each attach.
CMUX_REMOTE_EXPORT uint32_t cmux_remote_shim_order_input(uint32_t* ctl_seq);

}  // extern "C"

// What generated/remote_shim.inc and remote_shim_local.mm call (the generator's interface,
// scripts/cmux-next/gen-chromium-host-wire.py). Nothing here blocks.
namespace cmux_remote {

using TlvReader = cmux_host::control::TlvReader;

class TlvWriter : public cmux_host::control::TlvWriter {
 public:
  // An NSView* travels as its page view token (ChromiumHostPageView, task 040): the client
  // numbers each view the first time it crosses and keeps the number on the view, so it dies
  // with the view and is never another view's; NULL is 0.
  void View(void* ns_view);
};

// Control channel; queued before the first attach (never dropped: past the channel's quota the
// excess is counted). A state op (one value per browser, such as zoom or geometry) with `token` 0
// replaces its waiting predecessor, as the channel coalesces it. `token` 0: none. False when the
// op is not sent: no host (after a detach), over a frame bound, or an optional op the host's
// HELLO did not list.
bool Post(uint16_t op, uint32_t token, const TlvWriter& args);
// The input ring (tasks 041 and 042); the control channel until the ring lands.
bool PostInput(uint16_t op, uint32_t token, const TlvWriter& args);
// Post, with `token` registered: the host's REPLY for it reaches the reply callback once.
bool PostForReply(uint16_t op, uint32_t token, const TlvWriter& args);
// Recorded in the session's replay log, which every attach sends ahead of INITIALIZE, so a
// restarted host starts with the current values: a setter keeps its latest call, a page scheme
// its latest call per page id, other ops each distinct call. Also sent at once when a host is
// attached: before INITIALIZE as it is, after it as a post. A `token` other than 0 asks the
// host's verdict once (PostForReply). Returns the client's check of the arguments, the
// in-process shim's own: 1 accepted, 0 refused (nothing recorded).
int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter& args);
// Never 0.
uint32_t NextToken();
// Browser and window ids from 1 << 20, so they never meet one Chromium assigned; DevTools
// message ids below 2^30 (the header's shim-internal range), from 2^29 so they never meet the
// host shim's own counter. 0 when the range is used up.
int32_t MintID(uint16_t op);
inline constexpr int32_t kFirstMintedBrowserID = 1 << 20;
inline constexpr int32_t kFirstMintedDevToolsID = 1 << 29;
inline constexpr int32_t kEndMintedDevToolsID = 1 << 30;
// A malloc'd copy, freed by cmux_shim_free or cmux_shim_free_owned.
char* Dup(const std::string& text);
void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards);
TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key);
// The callback of a policy export (tasks 030-033 read it); NULL until set.
void SetPolicy(uint16_t op, void* fn);
void* Policy(uint16_t op);
// The rings passed to attach (NULL while detached), for remote_shim_local.mm.
void* InputRing();
void* OutputRing();

}  // namespace cmux_remote
