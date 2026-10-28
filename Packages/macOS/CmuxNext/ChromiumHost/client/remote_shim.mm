// libcmux_cef_shim_remote.dylib (remote_shim_runtime.h): the runtime the generated exports call,
// and the local exports that need no function pointer. Plain C++ so that
// scripts/cmux-next/tests/remote-shim-abi.test.sh builds it on any machine; built for cmux by scripts/cmux-next/build-chromium-host.sh.
//
// Wire (chromium_host_control.h frames, fields as chromium_host_tlv.h):
//   cmux -> host  HELLO first; then generated op ids 1..kOpCount with the export's arguments.
//                 INITIALIZE is kOpInitialize: cmux_shim_initialize's five paths, severity,
//                 locale, accept languages and switches (StrList)
//   host -> cmux  HELLO       after the attach MIRRORs (chromium_host_tlv.h)
//                 kOpEvent    i32 kind, i32 browser, i32 request, i64 a, i64 b, str s1, str s2
//                 kOpMirror   i32 mirror op, bytes key (EncodeFields), then bytes value, or no
//                             value to forget the key; before the EVENT that refreshes it
//                 kOpAck      `token`'s op ran: its pending marks clear
//                 kOpReply    the answer to an awaited `token`, its fields to the reply callback;
//                             its op ran, so its pending marks clear first; a password reveal's
//                             (PostPasswordReveal) to its own sink only: one bytes field, the
//                             password, or none
//                 kOpInputAck (i32 browser, i32 kind, u32 seq) per dispatched move or wheel tick,
//                             to the input ack callback (chromium_host_tlv.h)
//                 kOpInputDispatched, kOpHostHang  the ring input the host's UI thread
//                             dispatched and its hangs (host_hang_watcher.h), to the host watch
//                             callback; kOpAck and kOpReply ack control-channel input there too
// Anything else from the host is malformed and ends it, as bad_message::ReceivedBadMessage ends
// a renderer (content/browser/bad_message.cc).

#include "chromium_host_wire.h"
#include "cmux_cef_shim.h"
#include "cmux_page_path.h"
#include "host_energy_saver.h"
#include "host_hang_watcher.h"
#include "host_locks.h"
#include "host_provider_link.h"
#include "host_resize.h"
#include "remote_shim_choosers.h"
#include "remote_shim_mirror.h"
#include "remote_shim_runtime.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <pthread.h>
#include <unistd.h>
#if !defined(__APPLE__)
#include <sys/syscall.h>
#endif

#include "generated/remote_shim.inc"

namespace cmux_remote {
namespace {

using cmux_host::control::Channel;
using cmux_host::control::End;
using cmux_host::control::Field;
using cmux_host::control::kOpHello;
using cmux_host::control::kOpInputAck;
using cmux_host::control::kTagNull;
using cmux_host::control::Message;

bool OnMainThread() {
#if defined(__APPLE__)
  return pthread_main_np() == 1;
#else
  return syscall(SYS_gettid) == getpid();
#endif
}

#define CMUX_REMOTE_ASSERT_MAIN() assert(OnMainThread() && "the remote shim is main-thread only")

void RunMainTask(void* task) {
  std::unique_ptr<std::function<void()>> run(static_cast<std::function<void()>*>(task));
  (*run)();
}

int EndReason(End end) {
  switch (end) {
    case End::kClosed:
      return CMUX_REMOTE_END_CLOSED;
    case End::kPeerClosed:
      return CMUX_REMOTE_END_PEER_CLOSED;
    case End::kMalformed:
      return CMUX_REMOTE_END_MALFORMED;
    case End::kQuotaCeiling:
      return CMUX_REMOTE_END_QUOTA;
    case End::kIoError:
      return CMUX_REMOTE_END_IO_ERROR;
  }
  return CMUX_REMOTE_END_IO_ERROR;
}

Message MakeMessage(uint16_t op, uint32_t token, std::vector<Field> fields) {
  Message message;
  message.op = op;
  message.token = token;
  message.fields = std::move(fields);
  return message;
}

// Field `index` as text; nullopt for a NULL string or a missing field.
std::optional<std::string> Text(const TlvWriter& args, size_t index) {
  const std::vector<Field>& fields = args.fields();
  if (index >= fields.size() || fields[index].tag == kTagNull) return std::nullopt;
  return fields[index].bytes;
}

// The in-process shim's own refusals of a preinit call that need no disk or Chromium
// (CEFShim/src/shim_page_scheme.mm AddPage, shim_extensions_ui.mm add_native_messaging_dir):
// the host refuses the rest in its verdict.
bool PreinitAccepted(uint16_t op, const TlvWriter& args) {
  switch (op) {
    case kOpAddNativeMessagingDir:
      return !Text(args, 0).value_or(std::string()).empty();
    case kOpPageSchemeAdd:
    case kOpPageSchemeAddFirstParty:
    case kOpPageSchemeAddFirstPartyDynamic: {
      const std::optional<std::string> page_id = Text(args, 0);
      std::string domain;
      if (!page_id || !cmux_shim::NormalizePageId(*page_id, &domain)) return false;
      if (Text(args, 1).value_or(std::string()).empty()) return false;
      if (cmux_shim::IsReservedPageId(domain) != (op != kOpPageSchemeAdd)) return false;
      const std::string entry = Text(args, 4).value_or(std::string());
      return entry.find_first_of("/\\") == std::string::npos && entry != "." && entry != "..";
    }
    default:
      return true;
  }
}

// What a preinit call replaces in the replay log: a setter's earlier call, a page scheme's
// earlier call for the same domain (the in-process shim keeps one handler per domain,
// shim_page_scheme.mm AddPage), else only an equal call (add_native_messaging_dir appends).
std::string ReplayKey(uint16_t op, const std::vector<Field>& fields) {
  switch (op) {
    case kOpSetExtensionDeveloperMode:
    case kOpSetDefaultSearch:
    case kOpSetChromePolicyId:
    case kOpSetBackgroundColor:
    case kOpSetNewTabPageUrl:
    case kOpSetPopupWindowsEnabled:
    case kOpSetSuggestionEvents:
      return std::to_string(op);
    case kOpPageSchemeAdd:
    case kOpPageSchemeAddFirstParty:
    case kOpPageSchemeAddFirstPartyDynamic: {
      std::string domain;  // PreinitAccepted normalized it already
      if (!fields.empty()) cmux_shim::NormalizePageId(fields[0].bytes, &domain);
      return "page " + domain;
    }
    default: {
      std::string bytes;
      cmux_host::control::EncodeFields(fields, &bytes);
      return std::to_string(op) + " " + bytes;
    }
  }
}

// The channel's coalescing key for a state op: one value per browser (a hosted widget's
// geometry: per widget) that a newer call replaces, with no order against other ops
// (geometry, zoom, hosting modes, page visibility). Focus, the navigation guard and password
// fill are ordered against later ops, so they are not state.
std::optional<uint64_t> StateKeyFor(uint16_t op, const std::vector<Field>& fields) {
  switch (op) {
    case kOpWidgetSetGeometry:
    case kOpBrowserSetBackgroundColor:
    case kOpTabSetTransparentBackground:
    case kOpBrowserSetResizeSync:
    case kOpBrowserSetDetachedHosting:
    case kOpBrowserSetPageVisibility:
    case kOpSetZoomLevel:
    case kOpSetAccessibility:
    case kOpDevtoolsSetPlacement:
    case cmux_host::kOpPageResize:  // per page view; a fenced one has a token and is never replaced
      if (fields.empty()) return std::nullopt;
      return cmux_host::control::StateKey(op, static_cast<int32_t>(fields[0].integer));
    default:
      return std::nullopt;
  }
}

// The ops of the one ordered input stream (task 092; chromium_host_wire.h, "One ordered input
// stream"): those of Chrome's RenderWidgetHostNSViewHost pipe
// (content/common/render_widget_host_ns_view.mojom) that change where input lands or that input
// must reach first: focus (OnFirstResponderChanged), the active page and embedder activity
// (OnWindowIsKeyChanged), geometry (OnBoundsInWindowChanged), IME (ImeSetComposition,
// ImeCommitText, ImeFinishComposingText, ImeCancelComposition: p04-input-064), so a commit never
// passes the key that made it; edit commands (ExecuteEditCommand) join as task 047 adds them.
// Each carries its control seq and the input seq it follows; input frames name the last one.
bool IsOrderedOp(uint16_t op) {
  switch (op) {
    case kOpSetFocus:
    case kOpDevtoolsSetFocus:
    case kOpBrowserSetEmbedderActive:
    case kOpTabActivate:
    case kOpDevtoolsSetPlacement:
    case kOpBrowserImeSetComposition:
    case kOpBrowserImeCommitText:
    case kOpBrowserImeFinishComposing:
    case kOpBrowserImeCancelComposition:
    case cmux_host::kOpPageResize:
      return true;
    default:
      return false;
  }
}

// Input that goes on the control channel, not the ring: PostInput's ops, and the scripted click.
// Each is a coalescing boundary: a state op never replaces a waiting one across it.
bool IsControlInputOp(uint16_t op) {
  return op == kOpTabSendClick;
}

// A copy of the send right `fence` to the host's fence inbox (host_resize.h, SendFence); false
// when it was not sent, and always where there is no Mach (the tests on Linux).
bool SendFenceRight(uint32_t channel, uint32_t fence, uint64_t seq) {
#if defined(__APPLE__)
  return cmux_host::SendFence(channel, fence, seq);
#else
  (void)channel;
  (void)fence;
  (void)seq;
  return false;
#endif
}

// The name the host's HELLO lists when it takes `op`: an optional op's symbol (kOptionalExports)
// or kEnergySaverHelloName; nullptr for an op every host takes.
const char* OptionalExportName(uint16_t op) {
  if (op == cmux_host::kOpEnergySaver) return cmux_host::kEnergySaverHelloName;
  if (op == kOpSetLockHandler) return cmux_host::kLocksHelloName;
  if (op == cmux_host::kOpProviderLink) return cmux_host::kProviderLinkHelloName;
  for (const OptionalExport& entry : kOptionalExports) {
    if (entry.op == op && op != 0) return entry.name;
  }
  return nullptr;
}

// The setter op of a chooser handler (remote_shim_choosers.h): its local export's op id.
uint16_t ChooserHandlerOp(cmux_host::choosers::Handler handler) {
  switch (handler) {
    case cmux_host::choosers::kColor:
      return kOpSetColorChooserHandler;
    case cmux_host::choosers::kDevice:
      return kOpSetDeviceChooserHandler;
    case cmux_host::choosers::kDesktopMedia:
      return kOpSetDesktopMediaHandler;
  }
  return 0;
}

// The dylib's state. The C ABI has no context argument, so there is one per process, as in
// libcmux_cef_shim.dylib.
class Runtime {
 public:
  void Configure(const cmux_remote_shim_callbacks& callbacks) {
    CMUX_REMOTE_ASSERT_MAIN();
    callbacks_ = callbacks;
    reply_ = callbacks.reply;
    reply_ctx_ = callbacks.ctx;
    ended_ = callbacks.ended;
    ended_ctx_ = callbacks.ctx;
  }

  void SetReply(void* ctx, cmux_remote_reply_fn reply) {
    CMUX_REMOTE_ASSERT_MAIN();
    reply_ = reply;
    reply_ctx_ = ctx;
  }

  void SetInputAck(void* ctx, cmux_remote_input_ack_fn ack) {
    CMUX_REMOTE_ASSERT_MAIN();
    input_ack_ = ack;
    input_ack_ctx_ = ctx;
  }

  void SetEnded(void* ctx, cmux_remote_ended_fn ended) {
    CMUX_REMOTE_ASSERT_MAIN();
    ended_ = ended;
    ended_ctx_ = ctx;
  }

  int Attach(int fd, void* in_ring, void* out_ring) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (callbacks_.post_main == nullptr || fd < 0 || link_ == Link::kAttached) return 0;
    const uint64_t generation = ++generation_;
    const cmux_remote_shim_callbacks callbacks = callbacks_;
    channel_ = std::make_unique<Channel>(
        fd,
        [callbacks](std::function<void()> task) {
          callbacks.post_main(callbacks.ctx, &RunMainTask, new std::function<void()>(std::move(task)));
        },
        [this, generation](std::vector<Message> batch) { Deliver(generation, std::move(batch)); },
        [this, generation](End end) { Ended(generation, end); });
    link_ = Link::kAttached;
    hello_ = false;
    in_ring_ = in_ring;
    out_ring_ = out_ring;
    TlvWriter hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    Send(MakeMessage(kOpHello, 0, hello.Take()));
    for (Replay& entry : replay_) {
      Send(entry.message);
      entry.message.token = 0;  // a restarted host applies it again; the verdict was asked once
    }
    std::erase_if(replay_, [](const Replay& entry) { return !entry.keep; });
    if (initialize_) Send(*initialize_);
    // A host starts with the saver off and applies this once initialize returned; it waits for
    // the HELLO, which says whether the host has the saver.
    if (energy_saver_ && energy_saver_->enabled) Route(EnergySaverMessage(*energy_saver_), std::nullopt);
    // The same for cmux's lock handler: a new host's fork starts with none.
    if (locks_.installed()) Route(LockHandlerMessage(true), std::nullopt);
    // The browser host's provider link, as the saver: kept for every host.
    if (provider_link_ && provider_link_->socket) Route(ProviderLinkMessage(*provider_link_), std::nullopt);
    Flush();
    AnswerDroppedReveals();
    return 1;
  }

  void Detach() {
    CMUX_REMOTE_ASSERT_MAIN();
    Disconnect();
  }

  bool attached() const { return link_ == Link::kAttached; }

  uint32_t last_reply_token() const {
    CMUX_REMOTE_ASSERT_MAIN();
    return last_reply_token_;
  }

  bool HostHasExport(const char* name) const {
    CMUX_REMOTE_ASSERT_MAIN();
    return name != nullptr && host_exports_.count(name) > 0;
  }

  void GetStats(cmux_remote_shim_stats* out) const {
    CMUX_REMOTE_ASSERT_MAIN();
    *out = stats_;
    if (channel_) {
      const cmux_host::control::Stats channel = channel_->stats();
      out->quota_excess += channel.quota_excess;
      out->coalesced += channel.coalesced;
      out->pending_messages = channel.pending_messages;
    }
  }

  bool Post(uint16_t op, uint32_t token, const TlvWriter& args) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (IsControlInputOp(op)) {
      ++boundary_;
      return PostControlInput(op, token, args);
    }
    return PostOp(op, token, args);
  }

  // Input on the control channel until the ring lands (041, 042): it keeps its place among the
  // posts, and a state op posted after it does not replace one posted before it.
  bool PostInput(uint16_t op, uint32_t token, const TlvWriter& args) {
    CMUX_REMOTE_ASSERT_MAIN();
    ++boundary_;
    return PostControlInput(op, token, args);
  }

  // The input ring's writer (tasks 041 and 042), for the frame it writes next: its input seq,
  // and in `ctl_seq` the control seq of the last ordered op posted before it (CtlSeqOf). 0 with
  // no host attached: the frame is not written, as a seq it took would never reach a host.
  uint32_t OrderInput(uint32_t* ctl_seq) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (ctl_seq != nullptr) *ctl_seq = 0;
    if (link_ != Link::kAttached) return 0;
    input_seq_ = cmux_host::NextSeq(input_seq_);
    ++boundary_;
    if (ctl_seq != nullptr) *ctl_seq = ctl_seq_;
    if (watches_host_) Tell(input_acks_.Written(input_seq_));
    return input_seq_;
  }

  // Main thread. Where the host watch's changes go (cmux_remote_shim_set_host_watch).
  void SetHostWatch(void* ctx, cmux_remote_host_watch_fn watch) {
    CMUX_REMOTE_ASSERT_MAIN();
    host_watch_ = watch;
    host_watch_ctx_ = ctx;
  }

  // Takes the send right to the attached host's fence inbox (0: none); the one held goes.
  int SetFenceChannel(uint32_t port) {
    CMUX_REMOTE_ASSERT_MAIN();
    ReleaseFenceChannel();
    fence_channel_ = port;
    if (link_ == Link::kAttached) return 1;
    ReleaseFenceChannel();  // no host to send to: the port names a host that is gone
    return 0;
  }

  // kOpPageResize (host_resize.h). With `fence` and a fence channel, the fence right goes to the
  // host's inbox first and the op waits for the host's answer (last_reply_token_). A
  // cmux_remote_page_resize_result.
  int PageResize(uint64_t view, int32_t browser, int32_t width, int32_t height, uint32_t fence,
                 uint32_t deadline_frames) {
    CMUX_REMOTE_ASSERT_MAIN();
    last_reply_token_ = 0;
    if (link_ != Link::kAttached || view == 0) return CMUX_REMOTE_RESIZE_NOT_SENT;
    cmux_host::PageResize resize;
    resize.view = view;
    resize.browser = browser;
    resize.width = width;
    resize.height = height;
    resize.deadline_frames = deadline_frames;
    if (fence != 0 && fence_channel_ != 0 && SendFence(fence, fence_seq_ + 1)) {
      resize.fence_seq = ++fence_seq_;
    }
    TlvWriter args;
    cmux_host::WritePageResize(resize, &args);
    if (resize.fence_seq == 0) {
      return Post(cmux_host::kOpPageResize, 0, args) ? CMUX_REMOTE_RESIZE_UNFENCED : CMUX_REMOTE_RESIZE_NOT_SENT;
    }
    // Not sent: the host's book drops the fence when a later seq comes.
    return PostForReply(cmux_host::kOpPageResize, NextToken(), args) ? CMUX_REMOTE_RESIZE_FENCED
                                                                     : CMUX_REMOTE_RESIZE_NOT_SENT;
  }

  // cmux_shim_set_energy_saver: kept for every host of the session, posted to the attached one,
  // which applies it only when its HELLO listed kEnergySaverHelloName (otherwise it is refused
  // here, as an optional op the host lacks). 1 when the attached host has the saver and the op
  // went out; 0 otherwise, as the in-process shim answers on a fork without the call. Before the
  // HELLO the op waits for it and the answer is 0: whether the host applies it is not known yet.
  // cmux_remote_shim_set_provider_link: kept for every host of the session, posted to the attached
  // one, which takes it only when its HELLO listed kProviderLinkHelloName (otherwise refused here,
  // as an optional op the host lacks). 1 when the attached host takes it and the op went out.
  int SetProviderLink(const cmux_host::ProviderLinkConfig& config) {
    CMUX_REMOTE_ASSERT_MAIN();
    provider_link_ = config;
    if (link_ != Link::kAttached) return 0;
    const bool known = hello_;
    TlvWriter args;
    cmux_host::WriteProviderLink(config, &args);
    const bool sent = Post(cmux_host::kOpProviderLink, 0, args);
    return known && sent && HostHasExport(cmux_host::kProviderLinkHelloName) ? 1 : 0;
  }

  int SetEnergySaver(int enabled, const char* exempt_scheme) {
    CMUX_REMOTE_ASSERT_MAIN();
    cmux_host::EnergySaver saver;
    saver.enabled = enabled != 0;
    if (exempt_scheme != nullptr) saver.exempt_scheme = exempt_scheme;
    energy_saver_ = saver;
    // With no host attached, the next attach sends it.
    if (link_ != Link::kAttached) return 0;
    const bool known = hello_;
    TlvWriter args;
    cmux_host::WriteEnergySaver(saver, &args);
    const bool sent = Post(cmux_host::kOpEnergySaver, 0, args);
    return known && sent ? 1 : 0;
  }

  // cmux_shim_set_lock_handler (host_locks.h): cmux's fn stays here for every host of the
  // session, and only its on/off goes to the attached host, which applies it only when its HELLO
  // listed kLocksHelloName (otherwise it is refused here, as an optional op the host lacks). 1 when
  // the attached host has the lock delegate and the op went out; 0 otherwise, as the in-process
  // shim answers on a fork without the call. Before the HELLO the op waits for it and the answer
  // is 0.
  int SetLockHandler(cmux_host::LockFn fn, void* context) {
    CMUX_REMOTE_ASSERT_MAIN();
    const bool was_installed = locks_.installed();
    locks_.Set(fn, context);
    if (link_ != Link::kAttached || (!was_installed && !locks_.installed())) return 0;
    const bool known = hello_;
    TlvWriter args;
    cmux_host::WriteLockHandler(locks_.installed(), &args);
    const bool sent = Post(kOpSetLockHandler, 0, args);
    return known && sent ? 1 : 0;
  }

  void SetFenceSender(cmux_remote_fence_send_fn send) {
    CMUX_REMOTE_ASSERT_MAIN();
    fence_send_ = send;
  }

  bool SendFence(uint32_t fence, uint64_t seq) {
    return fence_send_ ? fence_send_(fence_channel_, fence, seq) == 1 : SendFenceRight(fence_channel_, fence, seq);
  }

  bool PostForReply(uint16_t op, uint32_t token, const TlvWriter& args) {
    CMUX_REMOTE_ASSERT_MAIN();
    awaiting_.insert(token);  // an op that is not sent drops it again (Dropped, Refused)
    const bool sent = Post(op, token, args);
    last_reply_token_ = sent ? token : 0;
    return sent;
  }

  bool PostPasswordReveal(uint32_t token, const char* path, const char* id, PasswordRevealedFn revealed) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (token == 0 || revealed == nullptr || link_ != Link::kAttached) return false;
    TlvWriter args;
    args.Str(path);
    args.Str(id);
    // Kept only once Post took it: a refused post has its false and never reaches the sink.
    if (!Post(kOpPasswordReveal, token, args)) return false;
    reveals_[token] = revealed;
    return true;
  }

  int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter& args) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (!PreinitAccepted(op, args)) {
      if (token != 0) last_reply_token_ = 0;
      return 0;
    }
    if (token != 0) {
      awaiting_.insert(token);
      last_reply_token_ = token;
    }
    Replay& entry = Record(MakeMessage(op, token, args.fields()));
    if (link_ != Link::kAttached) return 1;  // the next attach sends it
    Message message = entry.message;
    entry.message.token = 0;
    if (initialize_) {
      Route(std::move(message), std::nullopt);  // a post, in order with the others
    } else {
      Send(message);
    }
    return 1;
  }

  int Initialize(const TlvWriter& args, void* ctx, cmux_shim_event_fn event) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (initialize_) return 0;
    event_ctx_ = ctx;
    event_fn_ = event;
    initialize_ = MakeMessage(kOpInitialize, 0, args.fields());
    if (link_ == Link::kAttached) Send(*initialize_);
    return 1;
  }

  uint32_t NextToken() {
    CMUX_REMOTE_ASSERT_MAIN();
    if (++token_ == 0) token_ = 1;
    return token_;
  }

  int32_t MintID(uint16_t op) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (op == kOpDevtoolsCall) return next_devtools_id_ < kEndMintedDevToolsID ? next_devtools_id_++ : 0;
    return next_browser_id_ < kEndMintedBrowserID ? next_browser_id_++ : 0;
  }

  void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards) {
    CMUX_REMOTE_ASSERT_MAIN();
    // With no host to ack it, a mark would never clear.
    if (link_ == Link::kDetached) return;
    mirror_.MarkPending(mirror_op, token, key.fields(), wildcards);
  }

  TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (link_ != Link::kAttached) {
      ++stats_.reads_unattached;
      return TlvReader();
    }
    return mirror_.Lookup(mirror_op, key.fields());
  }

  void SetPolicy(uint16_t op, void* fn) {
    CMUX_REMOTE_ASSERT_MAIN();
    policies_[op] = fn;
  }
  void* Policy(uint16_t op) const {
    CMUX_REMOTE_ASSERT_MAIN();
    const auto it = policies_.find(op);
    return it == policies_.end() ? nullptr : it->second;
  }

  void* in_ring() const { return in_ring_; }
  void* out_ring() const { return out_ring_; }

 private:
  enum class Link {
    kNotYet,    // before the first attach: posts queue
    kAttached,  // posts go out
    kDetached,  // the host is gone: posts fail until the next attach
  };

  // A preinit call in the replay log.
  struct Replay {
    std::string key;  // ReplayKey
    Message message;  // token: a verdict still to ask, 0 once asked
    bool keep = true;  // false: replaced while its verdict was unasked; sent once more, then dropped
  };

  static Message LockHandlerMessage(bool installed) {
    TlvWriter args;
    cmux_host::WriteLockHandler(installed, &args);
    return MakeMessage(kOpSetLockHandler, 0, args.Take());
  }

  static Message EnergySaverMessage(const cmux_host::EnergySaver& saver) {
    TlvWriter args;
    cmux_host::WriteEnergySaver(saver, &args);
    return MakeMessage(cmux_host::kOpEnergySaver, 0, args.Take());
  }

  static Message ProviderLinkMessage(const cmux_host::ProviderLinkConfig& config) {
    TlvWriter args;
    cmux_host::WriteProviderLink(config, &args);
    return MakeMessage(cmux_host::kOpProviderLink, 0, args.Take());
  }

  // Control-channel input on a host that acks its dispatch (watches_host_: attached, and its HELLO
  // listed kHangWatchHelloName) goes with a token; the kOpAck the host sends once the op ran
  // (HostContext::Ack after DispatchOp) is its ack in the input acks.
  bool PostControlInput(uint16_t op, uint32_t token, const TlvWriter& args) {
    const bool counted = token == 0 && watches_host_;
    if (counted) token = NextToken();
    const bool sent = PostOp(op, token, args);
    if (sent && counted) Tell(input_acks_.ControlWritten(token));
    return sent;
  }

  bool PostOp(uint16_t op, uint32_t token, const TlvWriter& args) {
    Message message = MakeMessage(op, token, args.fields());
    // Detached, the op is dropped: a seq it took would never reach the next host, and input
    // stamped with it would wait there.
    if (IsOrderedOp(op) && link_ != Link::kDetached) {
      ctl_seq_ = cmux_host::NextSeq(ctl_seq_);
      message.ctl_seq = ctl_seq_;
      message.after_input = input_seq_;
    }
    const std::optional<uint64_t> key = token == 0 ? StateKeyFor(op, message.fields) : std::nullopt;
    return Route(std::move(message), key);
  }

  // A post waiting for the first attach or for the host's HELLO.
  struct Queued {
    Message message;
    std::optional<uint64_t> key;  // StateKeyFor
    uint32_t boundary = 0;        // boundary_ when it was posted
    bool live = true;             // false: replaced by a newer state op
  };

  bool Send(const Message& message, std::optional<uint64_t> key = std::nullopt, uint32_t boundary = 0) {
    if (channel_->Send(message, key, boundary)) return true;
    KeepPlace(message);
    return Dropped(message.token);
  }

  // An ordered op that will not be sent keeps its place in the order as a kOpSeqMark, so input
  // written after it does not wait for it (OrderedStream).
  void KeepPlace(const Message& message) {
    if (message.ctl_seq == 0 || !channel_) return;
    Message mark = MakeMessage(cmux_host::control::kOpSeqMark, 0, {});
    mark.ctl_seq = message.ctl_seq;
    mark.after_input = message.after_input;
    channel_->Send(mark);
  }

  // Sends a post now or keeps its place in the queue: before the first attach, and after an
  // attach while an optional op waits for the HELLO that says whether the host has it.
  bool Route(Message message, std::optional<uint64_t> key) {
    switch (link_) {
      case Link::kNotYet:
        Enqueue(std::move(message), key);
        return true;
      case Link::kAttached:
        if (!hello_ && (OptionalExportName(message.op) != nullptr || !queued_.empty())) {
          Enqueue(std::move(message), key);
          return true;
        }
        return SendOrRefuse(message, key, boundary_);
      case Link::kDetached:
        return Dropped(message.token);
    }
    return false;
  }

  bool SendOrRefuse(const Message& message, std::optional<uint64_t> key, uint32_t boundary) {
    const char* optional = OptionalExportName(message.op);
    if (optional != nullptr && host_exports_.count(optional) == 0) {
      KeepPlace(message);
      return Refused(message.token);
    }
    return Send(message, key, boundary);
  }

  // Never drops: past the channel's quota the excess is counted, as the channel counts it
  // (message_quota_checker.cc), and a state op replaces its waiting predecessor when no input
  // was written between them (the outbox's rule, chromium_host_control.h).
  void Enqueue(Message message, std::optional<uint64_t> key) {
    if (key) {
      const auto it = queued_keys_.find(*key);
      if (it != queued_keys_.end() && it->second->boundary == boundary_) {
        it->second->live = false;
        --queued_live_;
        ++stats_.coalesced;
      }
    }
    queued_.push_back(Queued{std::move(message), key, boundary_, true});
    if (key) queued_keys_[*key] = &queued_.back();  // a deque keeps element addresses on push_back
    if (++queued_live_ > cmux_host::control::kQuotaMessages) ++stats_.quota_excess;
  }

  // Sends the queue in order. Before the HELLO it stops at the first optional op.
  void Flush() {
    while (!queued_.empty()) {
      Queued& front = queued_.front();
      if (front.live && !hello_ && OptionalExportName(front.message.op) != nullptr) return;
      if (front.key) {
        const auto it = queued_keys_.find(*front.key);
        if (it != queued_keys_.end() && it->second == &front) queued_keys_.erase(it);
      }
      if (front.live) {
        --queued_live_;
        SendOrRefuse(front.message, front.key, front.boundary);
      }
      queued_.pop_front();
    }
  }

  // Adds a preinit call to the replay log and returns its entry.
  Replay& Record(Message message) {
    std::string key = ReplayKey(message.op, message.fields);
    for (Replay& entry : replay_) {
      if (!entry.keep || entry.key != key) continue;
      if (entry.message.token == 0) {
        entry.message = std::move(message);
        return entry;
      }
      entry.keep = false;
      break;
    }
    replay_.push_back(Replay{std::move(key), std::move(message), true});
    return replay_.back();
  }

  // An op that will not reach the host: its token neither acks nor answers.
  bool Dropped(uint32_t token) {
    ++stats_.unsendable;
    Forget(token);
    return false;
  }

  // An optional op the host's shim does not export: a missing symbol in process.
  bool Refused(uint32_t token) {
    ++stats_.unsupported;
    Forget(token);
    return false;
  }

  void Forget(uint32_t token) {
    if (token == 0) return;
    mirror_.Ack(token);
    awaiting_.erase(token);
    if (const auto reveal = reveals_.find(token); reveal != reveals_.end()) {
      dropped_reveals_.emplace_back(*reveal);
      reveals_.erase(reveal);
    }
  }

  // A reveal whose op will not reach the host, or whose host is gone, ends as not found:
  // revealed(token, NULL, 0), as mojo::WrapCallbackWithDefaultInvokeIfNotRun answers a response
  // callback its pipe dropped (mojo/public/cpp/bindings/callback_helpers.h). Called once this
  // class's state is consistent, since a sink may post, attach or detach.
  void AnswerDroppedReveals() {
    std::vector<std::pair<uint32_t, PasswordRevealedFn>> dropped;
    dropped.swap(dropped_reveals_);
    for (const auto& [token, revealed] : dropped) revealed(token, nullptr, 0);
  }

  // Closes the channel. Its reader thread ends on its own and its end reaches Ended, which
  // destroys the channel there: destroying a Channel joins that thread, done by then.
  void Disconnect() {
    if (!channel_) return;
    // The host's open choosers went with it; their ends run before a next host can attach.
    if (hello_) choosers::Detach();
    channel_->Close();
    closing_.emplace(generation_, std::move(channel_));
    ++generation_;
    link_ = Link::kDetached;
    hello_ = false;
    in_ring_ = nullptr;
    out_ring_ = nullptr;
    // The next host has a new ring and a new ordered stream: both seqs start again.
    ctl_seq_ = 0;
    input_seq_ = 0;
    watches_host_ = false;
    Tell(input_acks_.Reset());  // nothing waits for a host that is gone
    stats_.unsendable += queued_live_;  // posts that waited for this host's HELLO
    queued_.clear();
    queued_keys_.clear();
    queued_live_ = 0;
    mirror_.Clear();
    awaiting_.clear();
    dropped_reveals_.insert(dropped_reveals_.end(), reveals_.begin(), reveals_.end());
    reveals_.clear();
    host_exports_.clear();
    ReleaseFenceChannel();  // the inbox was this host's
    // Last: cmux's lock fn frees its cursor and keys, and may call back into a detached shim.
    locks_.HostGone();
    // After the lock fn: a reveal's sink may post, attach or detach (AnswerDroppedReveals).
    AnswerDroppedReveals();
  }

  void ReleaseFenceChannel() {
#if defined(__APPLE__)
    if (fence_channel_ != 0) mach_port_deallocate(mach_task_self(), fence_channel_);
#endif
    fence_channel_ = 0;
  }

  void Deliver(uint64_t generation, std::vector<Message> batch) {
    CMUX_REMOTE_ASSERT_MAIN();
    for (const Message& message : batch) {
      // A callback below may have detached, or detached and attached again.
      if (generation != generation_) return;
      if (!Apply(message)) {
        Disconnect();
        if (ended_) ended_(ended_ctx_, CMUX_REMOTE_END_MALFORMED);
        return;
      }
    }
  }

  void Ended(uint64_t generation, End end) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (generation == generation_) {
      Disconnect();
      if (ended_) ended_(ended_ctx_, EndReason(end));
    }
    closing_.erase(generation);
  }

  // kOpInputAck: every record is checked before any reaches the callback, so a malformed ack
  // moves no page's input on.
  bool ApplyInputAck(const Message& message) {
    if (message.reply || message.token != 0) return false;
    struct Record {
      int32_t browser, kind;
      uint32_t seq;
    };
    std::vector<Record> records;
    TlvReader r(message.fields);
    while (!r.AtEnd()) {
      const Record record{r.I32(), r.I32(), r.U32()};
      if (!r.ok() || (record.kind != cmux_host::kMouse && record.kind != cmux_host::kWheel)) return false;
      records.push_back(record);
    }
    if (records.empty()) return false;
    for (const Record& record : records) {
      if (input_ack_) {
        input_ack_(input_ack_ctx_, record.browser, record.kind, record.seq);
      } else {
        ++stats_.input_acks_unhandled;
      }
    }
    return true;
  }

  // False for a malformed frame.
  bool Apply(const Message& message) {
    TlvReader r(message.fields);
    switch (message.op) {
      case kOpEvent: {
        const int32_t kind = r.I32();
        const int32_t browser = r.I32();
        const int32_t request = r.I32();
        const int64_t a = r.I64();
        const int64_t b = r.I64();
        const std::string s1 = r.Str().value_or(std::string());
        const std::string s2 = r.Str().value_or(std::string());
        if (!r.ok() || !r.AtEnd()) return false;
        // A lock push is cmux's lock fn's (host_locks.h), with no handler dropped.
        if (kind == CMUX_SHIM_LOCK) {
          locks_.Deliver(request, browser, static_cast<int>(a));
          return true;
        }
        // The chooser handlers' pushes go to cmux's handler fn, never to its event fn (host_choosers.h).
        if (choosers::IsHandlerEvent(kind)) return choosers::Deliver(kind, browser, request, a, b, s1);
        if (event_fn_) event_fn_(event_ctx_, kind, browser, request, a, b, s1.c_str(), s2.c_str());
        return true;
      }
      case kOpMirror: {
        const int32_t op = r.I32();
        const std::string key_bytes = r.Bytes();
        const bool forget = r.AtEnd();
        const std::string value_bytes = forget ? std::string() : r.Bytes();
        std::vector<Field> key;
        std::vector<Field> value;
        if (!r.ok() || !r.AtEnd() || op < 1 || op > kOpCount) return false;
        if (!cmux_host::control::DecodeFields(key_bytes, &key)) return false;
        if (!cmux_host::control::DecodeFields(value_bytes, &value)) return false;
        if (forget) {
          mirror_.Erase(static_cast<uint16_t>(op), key);
        } else {
          mirror_.Set(static_cast<uint16_t>(op), key, std::move(value));
        }
        return true;
      }
      case kOpAck:
        if (!message.fields.empty()) return false;
        mirror_.Ack(message.token);
        Tell(input_acks_.ControlAcked(message.token));
        return true;
      case kOpReply: {
        if (const auto reveal = reveals_.find(message.token); reveal != reveals_.end()) {
          // A malformed answer stays pending: the disconnect it causes answers it as not found.
          const Field* password = nullptr;
          if (!RevealedPassword(message, &password)) return false;
          const PasswordRevealedFn revealed = reveal->second;
          reveals_.erase(reveal);
          if (password == nullptr) {
            revealed(message.token, nullptr, 0);
          } else {
            revealed(message.token, password->bytes.data(), password->bytes.size());
          }
          return true;
        }
        std::string fields;
        if (awaiting_.erase(message.token) == 0) return false;  // a reply to no request
        if (!cmux_host::control::EncodeFields(message.fields, &fields)) return false;
        mirror_.Ack(message.token);  // the op ran: the callback reads what it changed
        Tell(input_acks_.ControlAcked(message.token));
        if (reply_) {
          reply_(reply_ctx_, message.token, fields.data(), fields.size());
        } else {
          ++stats_.replies_unhandled;
        }
        return true;
      }
      case kOpInputAck:
        return ApplyInputAck(message);
      case kOpHello: {
        const std::optional<std::string> wire = r.Str();
        std::vector<std::string> exports = r.StrList();
        if (!r.ok() || !r.AtEnd() || wire != std::optional<std::string>(kWireID)) return false;
        host_exports_ = std::unordered_set<std::string>(exports.begin(), exports.end());
        hello_ = true;
        // Input ordered from here on is counted against the host's dispatch acks.
        watches_host_ = host_exports_.count(cmux_host::hang::kHangWatchHelloName) > 0;
        Flush();
        // Behind the queue: the handlers cmux set go to this host.
        choosers::Attach(&chooser_transport_);
        if (callbacks_.ready) callbacks_.ready(callbacks_.ctx);
        AnswerDroppedReveals();
        return true;
      }
      case cmux_host::hang::kOpInputDispatched: {
        uint32_t seq = 0;
        if (!cmux_host::hang::ReadDispatched(message, &seq)) return false;
        Tell(input_acks_.Dispatched(seq));
        return true;
      }
      case cmux_host::hang::kOpHostHang: {
        cmux_host::hang::Hang hang;
        if (!cmux_host::hang::ReadHang(message, &hang)) return false;
        if (host_watch_) {
          host_watch_(host_watch_ctx_, CMUX_REMOTE_HOST_HANG, static_cast<int64_t>(hang.duration_ns), hang.flags);
        }
        return true;
      }
      default:
        return false;
    }
  }

  // One change of the input acks to the host watch callback.
  void Tell(cmux_host::hang::InputAcks::Change change) {
    using Change = cmux_host::hang::InputAcks::Change;
    if (host_watch_ == nullptr || change == Change::kNone) return;
    const int32_t event = change == Change::kOutstanding ? CMUX_REMOTE_HOST_INPUT_OUTSTANDING
                          : change == Change::kProgress  ? CMUX_REMOTE_HOST_INPUT_PROGRESS
                                                         : CMUX_REMOTE_HOST_INPUT_SETTLED;
    host_watch_(host_watch_ctx_, event, 0, 0);
  }

  // A password reveal's REPLY: one bytes field, the password, or none (`password` stays NULL:
  // not found). False when malformed.
  static bool RevealedPassword(const Message& message, const Field** password) {
    *password = nullptr;
    if (message.fields.empty()) return true;
    const Field& field = message.fields.front();
    if (message.fields.size() > 1 || field.type != cmux_host::control::Type::kBytes ||
        field.tag != cmux_host::control::kTagValue) {
      return false;
    }
    *password = &field;
    return true;
  }

  static bool SendChooserInstalled(void* context, cmux_host::choosers::Handler handler, bool installed) {
    TlvWriter args;
    cmux_host::choosers::WriteInstalled(installed, &args);
    return static_cast<Runtime*>(context)->Post(ChooserHandlerOp(handler), 0, args);
  }

  cmux_remote_shim_callbacks callbacks_ = {};
  const choosers::Transport chooser_transport_{this, &SendChooserInstalled};
  // Where REPLY frames go: the configured callback, or cmux_remote_shim_set_reply's.
  cmux_remote_reply_fn reply_ = nullptr;
  void* reply_ctx_ = nullptr;
  // Where kOpInputAck records go (cmux_remote_shim_set_input_ack).
  cmux_remote_input_ack_fn input_ack_ = nullptr;
  void* input_ack_ctx_ = nullptr;
  // Where the channel's end goes: the configured callback, or cmux_remote_shim_set_ended's.
  cmux_remote_ended_fn ended_ = nullptr;
  void* ended_ctx_ = nullptr;
  Link link_ = Link::kNotYet;
  std::unique_ptr<Channel> channel_;
  // Closed channels whose reader has not reported its end yet, by generation.
  std::unordered_map<uint64_t, std::unique_ptr<Channel>> closing_;
  // Bumped by every attach and disconnect: frames of an earlier channel are dropped.
  uint64_t generation_ = 0;
  void* in_ring_ = nullptr;
  void* out_ring_ = nullptr;
  // The host's HELLO came on this channel: host_exports_ is its list.
  bool hello_ = false;
  std::deque<Queued> queued_;
  // The live queued entry of each state key.
  std::unordered_map<uint64_t, Queued*> queued_keys_;
  size_t queued_live_ = 0;
  // Every preinit call that a new host needs, for the whole session.
  std::vector<Replay> replay_;
  std::optional<Message> initialize_;
  void* event_ctx_ = nullptr;
  cmux_shim_event_fn event_fn_ = nullptr;
  MirrorCache mirror_;
  // Tokens sent with PostForReply and not answered yet.
  std::unordered_set<uint32_t> awaiting_;
  // Password reveals sent and not answered yet, and where each answer goes.
  std::unordered_map<uint32_t, PasswordRevealedFn> reveals_;
  // Reveals Forget or Disconnect dropped, for AnswerDroppedReveals.
  std::vector<std::pair<uint32_t, PasswordRevealedFn>> dropped_reveals_;
  std::unordered_set<std::string> host_exports_;
  // The app's last Energy Saver state (cmux_shim_set_energy_saver), for the whole session.
  std::optional<cmux_host::EnergySaver> energy_saver_;
  // cmux's lock fn (cmux_shim_set_lock_handler), for the whole session, and the attached host's locks.
  cmux_host::LockClient locks_;
  // The browser host's provider link (cmux_remote_shim_set_provider_link), for the whole session.
  std::optional<cmux_host::ProviderLinkConfig> provider_link_;
  std::unordered_map<uint16_t, void*> policies_;
  uint32_t token_ = 0;
  // The token of the latest PostForReply or answered PostPreinit (0: that call sent nothing).
  uint32_t last_reply_token_ = 0;
  // Task 092: the last ordered op's control seq, and the last input frame's input seq. Reset
  // only at Disconnect: ops queued before the first attach keep the seqs they took, and with no
  // host attached OrderInput stamps nothing and a detached Post takes no seq.
  uint32_t ctl_seq_ = 0;
  uint32_t input_seq_ = 0;
  // The attached host's HELLO listed kHangWatchHelloName: OrderInput's seqs count against its
  // kOpInputDispatched and control-channel input's tokens against its kOpAck.
  bool watches_host_ = false;
  cmux_host::hang::InputAcks input_acks_;
  cmux_remote_host_watch_fn host_watch_ = nullptr;
  void* host_watch_ctx_ = nullptr;
  // Input written so far, on the ring or the control channel: the coalescing boundary.
  uint32_t boundary_ = 0;
  // A send right to the attached host's fence inbox (task 052), 0 while none; and the last
  // fence seq, which only grows (a new host's inbox starts empty).
  uint32_t fence_channel_ = 0;
  uint64_t fence_seq_ = 0;
  // nullptr: SendFenceRight (cmux_remote_shim_set_fence_sender).
  cmux_remote_fence_send_fn fence_send_ = nullptr;
  int32_t next_browser_id_ = kFirstMintedBrowserID;
  int32_t next_devtools_id_ = kFirstMintedDevToolsID;
  cmux_remote_shim_stats stats_ = {};
};

Runtime& R() {
  // Never destroyed: an exit-time destructor would race the main thread and the reader.
  static Runtime* runtime = new Runtime();
  return *runtime;
}

}  // namespace

void TlvWriter::View(void* view_token) {
  ViewToken(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(view_token)));
}

bool Post(uint16_t op, uint32_t token, const TlvWriter& args) {
  return R().Post(op, token, args);
}
bool PostInput(uint16_t op, uint32_t token, const TlvWriter& args) {
  // On the control channel until the ring lands (041, 042), in order with every ordered op, so
  // it takes no input seq; on the ring it is written with OrderInput's seqs.
  return R().PostInput(op, token, args);
}
bool PostForReply(uint16_t op, uint32_t token, const TlvWriter& args) {
  return R().PostForReply(op, token, args);
}
bool PostPasswordReveal(uint32_t token, const char* profile_cache_path, const char* id, PasswordRevealedFn revealed) {
  return R().PostPasswordReveal(token, profile_cache_path, id, revealed);
}
int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter& args) {
  return R().PostPreinit(op, token, args);
}
uint32_t NextToken() {
  return R().NextToken();
}
int32_t MintID(uint16_t op) {
  return R().MintID(op);
}
char* Dup(const std::string& text) {
  auto* out = static_cast<char*>(std::malloc(text.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, text.data(), text.size());
  out[text.size()] = '\0';
  return out;
}
void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards) {
  R().MarkPending(mirror_op, token, key, wildcards);
}
TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key) {
  return R().MirrorLookup(mirror_op, key);
}
void SetPolicy(uint16_t op, void* fn) {
  R().SetPolicy(op, fn);
}
void* Policy(uint16_t op) {
  return R().Policy(op);
}
void* InputRing() {
  return R().in_ring();
}
void* OutputRing() {
  return R().out_ring();
}

}  // namespace cmux_remote

using cmux_remote::R;

extern "C" {

void cmux_remote_shim_configure(const cmux_remote_shim_callbacks* callbacks) {
  R().Configure(callbacks ? *callbacks : cmux_remote_shim_callbacks{});
}

int cmux_remote_shim_attach(int ctl_fd, void* in_ring, void* out_ring) {
  return R().Attach(ctl_fd, in_ring, out_ring);
}

void cmux_remote_shim_detach(void) {
  R().Detach();
}

int cmux_remote_shim_attached(void) {
  return R().attached() ? 1 : 0;
}

int cmux_remote_shim_host_has_export(const char* name) {
  return R().HostHasExport(name) ? 1 : 0;
}

void cmux_remote_shim_get_stats(cmux_remote_shim_stats* out) {
  if (out != nullptr) R().GetStats(out);
}

uint32_t cmux_remote_shim_last_reply_token(void) {
  return R().last_reply_token();
}

void cmux_remote_shim_set_reply(void* ctx, cmux_remote_reply_fn reply) {
  R().SetReply(ctx, reply);
}

void cmux_remote_shim_set_input_ack(void* ctx, cmux_remote_input_ack_fn ack) {
  R().SetInputAck(ctx, ack);
}

void cmux_remote_shim_set_ended(void* ctx, cmux_remote_ended_fn ended) {
  R().SetEnded(ctx, ended);
}

int cmux_remote_shim_set_resize_fence_channel(unsigned int port) {
  return R().SetFenceChannel(port);
}

int cmux_remote_shim_page_resize(uint64_t view_token, int browser_id, int width, int height, unsigned int fence_port,
                                 unsigned int deadline_frames) {
  return R().PageResize(view_token, browser_id, width, height, fence_port, deadline_frames);
}

void cmux_remote_shim_set_fence_sender(cmux_remote_fence_send_fn send) {
  R().SetFenceSender(send);
}

uint32_t cmux_remote_shim_order_input(uint32_t* ctl_seq) {
  return R().OrderInput(ctl_seq);
}

int cmux_remote_shim_set_provider_link(const char* socket, const char* credential, const char* link_id, int host_pid,
                                       int listener_pid) {
  cmux_host::ProviderLinkConfig config;
  if (socket != nullptr && *socket != '\0') config.socket = socket;
  if (credential != nullptr) config.credential = credential;
  if (link_id != nullptr) config.link_id = link_id;
  config.host_pid = host_pid;
  config.listener_pid = listener_pid;
  if (config.socket && (config.credential.empty() || config.link_id.empty())) return 0;
  return R().SetProviderLink(config);
}

void cmux_remote_shim_set_host_watch(void* ctx, cmux_remote_host_watch_fn watch) {
  R().SetHostWatch(ctx, watch);
}

// --- local exports (chromium-host-ops.json class local) --------------------------------------

// The framework is the host's (task 101): nothing is mapped here.
CMUX_SHIM_EXPORT int cmux_shim_load(const char* framework_binary, char* err, size_t err_len) {
  (void)framework_binary;
  if (err != nullptr && err_len > 0) err[0] = '\0';
  return 1;
}

// The app process runs no CEF, so NSApp needs no CefAppProtocol.
CMUX_SHIM_EXPORT int cmux_shim_prepare_application(void) {
  return 1;
}

// Keeps `event` for the host's EVENT frames and sends INITIALIZE; CONTEXT_INITIALIZED comes
// later as an event. `schedule` is never called: the host runs Chromium's message loop
// (task 034). `key` is unused: keys route cmux-first (task 030). Returns 1 once INITIALIZE is
// sent or queued, 0 on a second call.
CMUX_SHIM_EXPORT int cmux_shim_initialize(const char* framework_dir,
                                          const char* main_bundle_path,
                                          const char* subprocess_path,
                                          const char* root_cache_path,
                                          const char* log_file,
                                          int log_severity,
                                          const char* locale,
                                          const char* accept_languages,
                                          const char* const* switches,
                                          void* ctx,
                                          cmux_shim_schedule_fn schedule,
                                          cmux_shim_event_fn event,
                                          cmux_shim_key_fn key) {
  (void)schedule;
  (void)key;
  cmux_remote::TlvWriter args;
  args.Str(framework_dir);
  args.Str(main_bundle_path);
  args.Str(subprocess_path);
  args.Str(root_cache_path);
  args.Str(log_file);
  args.I32(log_severity);
  args.Str(locale);
  args.Str(accept_languages);
  int count = 0;
  while (switches != nullptr && switches[count] != nullptr) ++count;
  args.StrList(switches, count);
  return R().Initialize(args, ctx, event);
}

// No external message pump in host mode (task 034).
CMUX_SHIM_EXPORT void cmux_shim_do_work(void) {}

// No external message pump in host mode: the host's own pump slices its passes.
CMUX_SHIM_EXPORT int cmux_shim_set_pump_time_slice(int64_t slice_us) {
  (void)slice_us;
  return 0;
}

// No external message pump in host mode: delayed work never reaches the app.
CMUX_SHIM_EXPORT int cmux_shim_set_schedule_delayed(cmux_shim_schedule_delayed_fn schedule_delayed) {
  (void)schedule_delayed;
  return 0;
}

// The Chromium Host applies Energy Saver: kOpEnergySaver, its own versioned op
// (ChromiumHost/src/host_energy_saver.h).
CMUX_SHIM_EXPORT int cmux_shim_set_energy_saver(int enabled, const char* exempt_scheme) {
  return R().SetEnergySaver(enabled, exempt_scheme);
}

// The Chromium Host runs the fork's lock delegate; cmux's fn hears its CMUX_SHIM_LOCK pushes
// (host_locks.h).
CMUX_SHIM_EXPORT int cmux_shim_set_lock_handler(void (*fn)(void* context, int event, int browser_id, int detail),
                                                void* context) {
  return R().SetLockHandler(fn, context);
}

// Per-tab attribution is in-process only: a tab's renderer is the Chromium Host's child, which the
// app does not sample, so there is no pid here. Host mode is task p14-energy-124a.
CMUX_SHIM_EXPORT int cmux_shim_renderer_pid(int browser_id) {
  (void)browser_id;
  return 0;
}

// Memory per hidden workspace is in-process only for the same reason: the renderers are the Chromium
// Host's children, so the app finds no pid for them and counts the sample unclear.
CMUX_SHIM_EXPORT int cmux_shim_renderer_frames(int* browser_ids, int* client_ids, int* frame_counts, int capacity) {
  (void)browser_ids;
  (void)client_ids;
  (void)frame_counts;
  (void)capacity;
  return 0;
}

// Strings this dylib returns are Dup's malloc'd copies.
CMUX_SHIM_EXPORT void cmux_shim_free(char* s) {
  std::free(s);
}

CMUX_SHIM_EXPORT void cmux_shim_free_owned(char* s) {
  std::free(s);
}

// Swift writes password entries for this binary, which compiles the same header; the host
// checks its own layout.
CMUX_SHIM_EXPORT int cmux_shim_password_entry_size(void) {
  return static_cast<int>(sizeof(cmux_shim_password_entry));
}

// A Mach port name is this process's: in the host it would name nothing, or another right.
// So nothing is sent and the result is a fork's without the call; host mode's fence goes with the
// page's resize, as a right in a Mach message (cmux_remote_shim_page_resize, task 052).
CMUX_SHIM_EXPORT int cmux_shim_browser_set_resize_fence(int browser_id, unsigned int fence_port,
                                                        unsigned int deadline_frames) {
  (void)browser_id;
  (void)fence_port;
  (void)deadline_frames;
  return 0;
}

// The host turns cursor events on itself (browser_host_main.mm): its page windows never show, so
// every page cursor comes to cmux as CMUX_SHIM_CURSOR. There is nothing for cmux to choose.
CMUX_SHIM_EXPORT void cmux_shim_set_cursor_events(int enabled) {
  (void)enabled;
}

// The host's views cannot become subviews of a view in this process: host mode shows the page
// as a hosted context in ChromiumHostPageView. So nothing is sent and the result is a fork's
// without the call; the cross-process attach is remote_cocoa's Application form (F2).
CMUX_SHIM_EXPORT int cmux_shim_browser_attach_view(int browser_id, void* parent_view) {
  (void)browser_id;
  (void)parent_view;
  return 0;
}

}  // extern "C"
