// libcmux_cef_shim_remote.dylib: the ABI of cmux_cef_shim.h (the same cmux_shim_abi_id) for
// host mode, where Chromium's browser process is the Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md 3.2). Every export returns at once: a post
// becomes a control channel frame, a mirror read reads the main-thread cache, a mint returns an
// id cmux chose. Chrome's model is a mojo Remote (mojo/public/cpp/bindings/remote.h): calls
// never wait for the other process, and calls made before the pipe is bound are queued.
//
// The exports are generated (generated/remote_shim.inc, scripts/cmux-next/gen-chromium-host-wire.py)
// except the `local` ones: remote_shim.mm (load, prepare_application, initialize, do_work, free,
// free_owned, password_entry_size, and set_lock_handler, whose fn ../src/host_locks.h's LockClient
// keeps, task 229) and remote_shim_local.mm (task 014b: the exports with a function-pointer
// parameter). This header is the interface both include.
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

#include "chromium_host_mint.h"
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
  uint64_t input_acks_unhandled;  // input ack records with no input ack callback
} cmux_remote_shim_stats;

// Main thread. The host dispatched a page's pointer move (kind 3) or wheel tick (kind 4) with
// input seq `seq` on its UI thread (kOpInputAck): the page view sends that
// page's next waiting one (ChromiumHostInputPacer).
typedef void (*cmux_remote_input_ack_fn)(void* ctx, int32_t browser_id, int32_t kind, uint32_t seq);

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
// pending marks, the awaited tokens and the posts still waiting for the HELLO, and ends each
// pending password reveal as not found (PostPasswordReveal); `ended` is not called. Posts fail until the next attach, which replays the preinit log (asking no verdict
// twice) and INITIALIZE to the new host. Ids and tokens keep counting.
CMUX_REMOTE_EXPORT void cmux_remote_shim_detach(void);
CMUX_REMOTE_EXPORT int cmux_remote_shim_attached(void);
// 1 when the attached host's HELLO listed `name`: an optional_exports symbol its shim defines
// (CEFForkFeatures reads this in host mode, not the remote dylib's own symbols).
CMUX_REMOTE_EXPORT int cmux_remote_shim_host_has_export(const char* name);
CMUX_REMOTE_EXPORT void cmux_remote_shim_get_stats(cmux_remote_shim_stats* out);
// Main thread. The token of the latest op sent for a REPLY (an async op, a non-void preinit's
// verdict): read right after the call, it names that call's answer, which the reply callback
// delivers under it (task 018: CEFHostReplies awaits it). 0 when that call sent nothing.
CMUX_REMOTE_EXPORT uint32_t cmux_remote_shim_last_reply_token(void);
// Main thread. REPLY frames go to `reply(ctx, ...)` from now on, in place of the configured
// callback and its ctx (task 018: CEFRemoteShim hands them to CEFHostReplies); NULL drops them
// (replies_unhandled). The next cmux_remote_shim_configure sets them again.
CMUX_REMOTE_EXPORT void cmux_remote_shim_set_reply(void* ctx, cmux_remote_reply_fn reply);
// Main thread. kOpInputAck records go to `ack(ctx, ...)`, in the host's dispatch order; NULL
// drops them (input_acks_unhandled). Detach keeps it: the next host's acks go there too.
CMUX_REMOTE_EXPORT void cmux_remote_shim_set_input_ack(void* ctx, cmux_remote_input_ack_fn ack);
// Main thread. The channel's end goes to `ended(ctx, reason)` from now on, in place of the
// configured callback and its ctx (task 091: CEFRemoteShim hands it to CEFHostReplies, whose
// tokens then resolve as hostGone in that turn); NULL drops it. A detach cmux asks for is never
// reported. The next cmux_remote_shim_configure sets it again.
CMUX_REMOTE_EXPORT void cmux_remote_shim_set_ended(void* ctx, cmux_remote_ended_fn ended);
// Main thread. The input ring's writer (ChromiumHostInputRing, tasks 041 and 042) calls it for
// each frame of an input kind (IsOrderedInput) it writes, in write order (kPing and kStats keep
// `seq` as their request id): returns the frame's input seq (Header::seq) and puts in
// `ctl_seq` the control seq to stamp (SetCtlSeq), that of the last ordered op posted before it.
// Ordered ops carry the returned seq as the input they follow (task 092; chromium_host_wire.h,
// "One ordered input stream"). With no host attached it returns 0 and `ctl_seq` 0: the writer
// writes nothing for that frame. Both seqs start again with the next host.
CMUX_REMOTE_EXPORT uint32_t cmux_remote_shim_order_input(uint32_t* ctl_seq);
// What the host watch callback hears (host_hang_watcher.h).
typedef enum {
  CMUX_REMOTE_HOST_INPUT_OUTSTANDING = 0,  // input the host has not dispatched yet: the first seq waits
  CMUX_REMOTE_HOST_INPUT_PROGRESS = 1,     // the host dispatched input; later input still waits
  CMUX_REMOTE_HOST_INPUT_SETTLED = 2,      // the host dispatched every seq written (or went away)
  CMUX_REMOTE_HOST_HANG = 3,               // a UI-thread hang of the host: `a` its length in ns, `b` its
                                           // kOpHostHang flags (1 still running, 2 dumped, 4 the
                                           // turn's end of a hang the still-running report sent)
} cmux_remote_host_watch_event;
// Main thread, in the order the host's frames came, and from inside the input posts
// (cmux_remote_shim_order_input, and on the control channel cmux_shim_browser_send_wheel,
// cmux_shim_browser_send_locked_mouse_move, cmux_shim_widget_send_input, cmux_shim_tab_send_click:
// OUTSTANDING) and cmux_remote_shim_detach (SETTLED). `a` and `b` are 0 but for a hang.
typedef void (*cmux_remote_host_watch_fn)(void* ctx, int32_t event, int64_t a, int64_t b);
// Main thread. The host watch's changes go to `watch(ctx, ...)` from now on; NULL drops them. Input
// is counted only on a host whose HELLO listed kHangWatchHelloName: ring input against its
// kOpInputDispatched, control-channel input (sent with a token) against its kOpAck of the op.
CMUX_REMOTE_EXPORT void cmux_remote_shim_set_host_watch(void* ctx, cmux_remote_host_watch_fn watch);
// Main thread. Takes `port`, a send right to the attached host's resize fence inbox (the
// bootstrap name cmux passed as --resize-fence, looked up off the main thread after the HELLO;
// ChromiumHost/src/host_resize.h, task 052): 1 when kept until the host detaches, 0 (the right
// released) with no host attached.
CMUX_REMOTE_EXPORT int cmux_remote_shim_set_resize_fence_channel(unsigned int port);
// What cmux_remote_shim_page_resize did.
typedef enum {
  CMUX_REMOTE_RESIZE_NOT_SENT = 0,  // no host attached, view token 0, or over a bound
  CMUX_REMOTE_RESIZE_UNFENCED = 1,  // sent with no fence: no answer comes
  CMUX_REMOTE_RESIZE_FENCED = 2,    // sent with its fence: the host answers
} cmux_remote_page_resize_result;
// Main thread. Sizes page view `view_token`'s page (`browser_id`: the tab it shows) to `width` x
// `height` points with kOpPageResize, on the ordered stream. With `fence_port` (a send right of
// this process to a -[CAContext createFencePort] port) and a fence channel, a copy of that right
// goes to the host first, which gives the fork its own right before the page's frame change
// (deadline `deadline_frames` display frames, at most kMaxFenceDeadlineFrames) and answers with
// i32 1 when the fork took it: CMUX_REMOTE_RESIZE_FENCED, the answer's token in
// cmux_remote_shim_last_reply_token. With no fence, no channel or a full inbox it goes unfenced.
// The caller's right stays its own either way.
CMUX_REMOTE_EXPORT int cmux_remote_shim_page_resize(uint64_t view_token, int browser_id, int width, int height,
                                                    unsigned int fence_port, unsigned int deadline_frames);
// Sends a copy of the send right `fence` and its `seq` to the fence inbox `channel`: 1 when sent.
typedef int (*cmux_remote_fence_send_fn)(unsigned int channel, unsigned int fence, uint64_t seq);
// Main thread. How cmux_remote_shim_page_resize sends a fence right: nullptr (the default) is the
// Mach message of host_resize.h (SendFence), which sends nothing where there is no Mach; the
// tests pass their own to drive the fenced path on Linux.
CMUX_REMOTE_EXPORT void cmux_remote_shim_set_fence_sender(cmux_remote_fence_send_fn send);
// Main thread. The browser host's provider link for the Chromium Host (kOpProviderLink,
// ChromiumHost/src/host_provider_link.h): its socket (NULL or "" ends the
// link), the relay credential derived from the daemon-minted secret, the link id cmux names the
// host by, and the pids the socket's peer may be. Kept for every host of the session, as the
// Energy Saver is. 1 when the attached host takes it (its HELLO listed cmux_host_provider_link)
// and it went out; 0 otherwise (no host yet: the next attach sends it).
CMUX_REMOTE_EXPORT int cmux_remote_shim_set_provider_link(const char* socket, const char* credential,
                                                          const char* link_id, int host_pid, int listener_pid);

}  // extern "C"

// What generated/remote_shim.inc and remote_shim_local.mm call (the generator's interface,
// scripts/cmux-next/gen-chromium-host-wire.py). Nothing here blocks.
namespace cmux_remote {

using TlvReader = cmux_host::control::TlvReader;

class TlvWriter : public cmux_host::control::TlvWriter {
 public:
  // A parent view argument (NSView* in the in-process ABI): in host mode cmux passes the token it
  // minted for the page view (ChromiumHostPageView, CEFRuntime.mintPageViewToken: never 0, never
  // reused), not a view pointer, and it travels as is; NULL is 0.
  void View(void* view_token);
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
// cmux_shim_password_reveal's wire, for remote_shim_local.mm's
// LocalTransport::send_password_reveal, with its DeliverPasswordReveal as `revealed`:
// kOpPasswordReveal with str profile_cache_path and str id under `token`. The host's REPLY is
// one bytes field, the password, or none when its shim found none; it goes to `revealed` once,
// on main (the bytes valid during the call), never to the reply callback, and nothing here
// logs or counts it. A reveal that gets no answer ends with revealed(token, NULL, 0) once:
// a detach, the host's end or a malformed frame, or a queued op that was then not sent.
// False when not sent: no host attached, or the channel refused it; `revealed` never runs then.
// The password crosses as a plain frame: the channel's buffers are not zeroed, as Chrome's
// plaintext answer crosses its IPC (passwords_private_delegate_impl.cc).
using PasswordRevealedFn = bool (*)(uint32_t token, const char* password, size_t length);
bool PostPasswordReveal(uint32_t token, const char* profile_cache_path, const char* id, PasswordRevealedFn revealed);
// Never 0.
uint32_t NextToken();
// Browser ids in [1 << 20, 1 << 30), so they never meet one Chromium assigned nor one the host mints
// for a tab it opened for a window request (task 031); DevTools message ids below
// 2^30 (the header's shim-internal range), from 2^29 so they never meet the host shim's own
// counter (chromium_host_mint.h; the host maps them, host_client_ids.h). 0 when the range is used up.
int32_t MintID(uint16_t op);
inline constexpr int32_t kFirstMintedBrowserID = cmux_host::mint::kFirstBrowserID;
inline constexpr int32_t kEndMintedBrowserID = cmux_host::mint::kFirstHostBrowserID;
inline constexpr int32_t kFirstMintedDevToolsID = cmux_host::mint::kFirstDevToolsID;
inline constexpr int32_t kEndMintedDevToolsID = cmux_host::mint::kEndDevToolsID;
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
