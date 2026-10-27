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
//                             its op ran, so its pending marks clear first
// Anything else from the host is malformed and ends it, as bad_message::ReceivedBadMessage ends
// a renderer (content/browser/bad_message.cc).

#include "cmux_cef_shim.h"
#include "cmux_page_path.h"
#include "host_energy_saver.h"
#include "host_resize.h"
#include "host_tracing.h"
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
#include <time.h>
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
  for (const OptionalExport& entry : kOptionalExports) {
    if (entry.op == op && op != 0) return entry.name;
  }
  return nullptr;
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
  }

  void SetReply(void* ctx, cmux_remote_reply_fn reply) {
    CMUX_REMOTE_ASSERT_MAIN();
    reply_ = reply;
    reply_ctx_ = ctx;
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
    Flush();
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
    if (IsControlInputOp(op)) ++boundary_;
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

  // Input on the control channel until the ring lands (041, 042): it keeps its place among the
  // posts, and a state op posted after it does not replace one posted before it.
  bool PostInput(uint16_t op, uint32_t token, const TlvWriter& args) {
    CMUX_REMOTE_ASSERT_MAIN();
    ++boundary_;
    return Post(op, token, args);
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
    return input_seq_;
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

  // cmux_cef_begin_tracing in host mode (host_tracing.h, task p09-observability-104): TRACE_START
  // with the host ring's recording categories and `categories` for Chromium; `started` runs once,
  // on the main thread, with the host's answer, or with 0 when the host ends first. 0 (nothing
  // sent, `started` never runs) with no host, before its HELLO, or when its HELLO does not list
  // kTracingHelloName.
  int BeginTracing(const char* categories, cmux_cef_trace_started_fn started, void* ctx) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (started == nullptr || !HostTraces()) return 0;
    cmux_host::TraceStart start;
    start.ring_categories = cmux_host::kTraceRecordingCategories;
    start.chromium_categories = categories != nullptr ? categories : "";
    TlvWriter args;
    cmux_host::WriteTraceStart(start, &args);
    return SendTrace(cmux_host::kOpTraceStart, args, TraceWaiter{started, nullptr, ctx});
  }

  // cmux_cef_end_tracing in host mode: TRACE_STOP with the ring and `path`; `written` runs once on
  // the main thread with the path the host's Chromium reported, or NULL. 0 as BeginTracing, and for
  // a path that is not absolute or does not end in ".json" (the in-process shim's rule).
  int EndTracing(const char* path, cmux_cef_trace_written_fn written, void* ctx) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (written == nullptr || path == nullptr || path[0] != '/' || !HostTraces()) return 0;
    const std::string text(path);
    if (text.size() < 5 || text.compare(text.size() - 5, 5, ".json") != 0) return 0;
    cmux_host::TraceStop stop;
    stop.ring = true;
    stop.chromium_path = text;
    TlvWriter args;
    cmux_host::WriteTraceStop(stop, &args);
    return SendTrace(cmux_host::kOpTraceStop, args, TraceWaiter{nullptr, written, ctx});
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
    return next_browser_id_ < std::numeric_limits<int32_t>::max() ? next_browser_id_++ : 0;
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

  // A TRACE_START or TRACE_STOP waiting for its answer: one of the two callbacks.
  struct TraceWaiter {
    cmux_cef_trace_started_fn started;
    cmux_cef_trace_written_fn written;
    void* ctx;
  };

  bool HostTraces() const {
    return link_ == Link::kAttached && hello_ && host_exports_.count(cmux_host::kTracingHelloName) > 0;
  }

  int SendTrace(uint16_t op, const TlvWriter& args, TraceWaiter waiter) {
    const uint32_t token = NextToken();
    trace_waiters_[token] = waiter;
    if (Send(MakeMessage(op, token, args.fields()))) return 1;
    trace_waiters_.erase(token);  // not sent: the callback never runs
    return 0;
  }

  // The host's answer to a trace op; false for a malformed one (its callback still runs, with
  // the failure value).
  bool AnswerTrace(uint32_t token, const std::vector<Field>& fields) {
    const auto found = trace_waiters_.find(token);
    const TraceWaiter waiter = found->second;
    trace_waiters_.erase(found);
    if (waiter.started) {
      const std::optional<cmux_host::TraceStartAnswer> answer = cmux_host::DecodeTraceStartAnswer(fields);
      waiter.started(waiter.ctx, answer && answer->chromium ? 1 : 0);
      return answer.has_value();
    }
    const std::optional<cmux_host::TraceStopAnswer> answer = cmux_host::DecodeTraceStopAnswer(fields);
    waiter.written(waiter.ctx, answer && answer->path ? answer->path->c_str() : nullptr);
    return answer.has_value();
  }

  // The host ended with trace ops unanswered: each callback runs once, with its failure value.
  static void FailTraces(const std::unordered_map<uint32_t, TraceWaiter>& waiters) {
    for (const auto& entry : waiters) {
      const TraceWaiter& waiter = entry.second;
      if (waiter.started) {
        waiter.started(waiter.ctx, 0);
      } else {
        waiter.written(waiter.ctx, nullptr);
      }
    }
  }

  static Message EnergySaverMessage(const cmux_host::EnergySaver& saver) {
    TlvWriter args;
    cmux_host::WriteEnergySaver(saver, &args);
    return MakeMessage(cmux_host::kOpEnergySaver, 0, args.Take());
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
  }

  // Closes the channel. Its reader thread ends on its own and its end reaches Ended, which
  // destroys the channel there: destroying a Channel joins that thread, done by then.
  void Disconnect() {
    if (!channel_) return;
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
    stats_.unsendable += queued_live_;  // posts that waited for this host's HELLO
    queued_.clear();
    queued_keys_.clear();
    queued_live_ = 0;
    mirror_.Clear();
    awaiting_.clear();
    host_exports_.clear();
    ReleaseFenceChannel();  // the inbox was this host's
    // Last: a callback may call back into the shim, which is detached by now.
    std::unordered_map<uint32_t, TraceWaiter> unanswered;
    unanswered.swap(trace_waiters_);
    FailTraces(unanswered);
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
        if (callbacks_.ended) callbacks_.ended(callbacks_.ctx, CMUX_REMOTE_END_MALFORMED);
        return;
      }
    }
  }

  void Ended(uint64_t generation, End end) {
    CMUX_REMOTE_ASSERT_MAIN();
    if (generation == generation_) {
      Disconnect();
      if (callbacks_.ended) callbacks_.ended(callbacks_.ctx, EndReason(end));
    }
    closing_.erase(generation);
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
        return true;
      case kOpReply: {
        if (trace_waiters_.count(message.token) > 0) return AnswerTrace(message.token, message.fields);
        std::string fields;
        if (awaiting_.erase(message.token) == 0) return false;  // a reply to no request
        if (!cmux_host::control::EncodeFields(message.fields, &fields)) return false;
        mirror_.Ack(message.token);  // the op ran: the callback reads what it changed
        if (reply_) {
          reply_(reply_ctx_, message.token, fields.data(), fields.size());
        } else {
          ++stats_.replies_unhandled;
        }
        return true;
      }
      case kOpHello: {
        const std::optional<std::string> wire = r.Str();
        std::vector<std::string> exports = r.StrList();
        if (!r.ok() || !r.AtEnd() || wire != std::optional<std::string>(kWireID)) return false;
        host_exports_ = std::unordered_set<std::string>(exports.begin(), exports.end());
        hello_ = true;
        Flush();
        if (callbacks_.ready) callbacks_.ready(callbacks_.ctx);
        return true;
      }
      default:
        return false;
    }
  }

  cmux_remote_shim_callbacks callbacks_ = {};
  // Where REPLY frames go: the configured callback, or cmux_remote_shim_set_reply's.
  cmux_remote_reply_fn reply_ = nullptr;
  void* reply_ctx_ = nullptr;
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
  // Trace ops sent and not answered yet, by token.
  std::unordered_map<uint32_t, TraceWaiter> trace_waiters_;
  std::unordered_set<std::string> host_exports_;
  // The app's last Energy Saver state (cmux_shim_set_energy_saver), for the whole session.
  std::optional<cmux_host::EnergySaver> energy_saver_;
  std::unordered_map<uint16_t, void*> policies_;
  uint32_t token_ = 0;
  // The token of the latest PostForReply or answered PostPreinit (0: that call sent nothing).
  uint32_t last_reply_token_ = 0;
  // Task 092: the last ordered op's control seq, and the last input frame's input seq. Reset
  // only at Disconnect: ops queued before the first attach keep the seqs they took, and with no
  // host attached OrderInput stamps nothing and a detached Post takes no seq.
  uint32_t ctl_seq_ = 0;
  uint32_t input_seq_ = 0;
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

// No external message pump in host mode: delayed work never reaches the app.
CMUX_SHIM_EXPORT int cmux_shim_set_schedule_delayed(cmux_shim_schedule_delayed_fn schedule_delayed) {
  (void)schedule_delayed;
  return 0;
}

// The Chromium Host applies Energy Saver: kOpEnergySaver, its own versioned op
// (ChromiumHost/src/host_energy_saver.h, p14-energy-045).
CMUX_SHIM_EXPORT int cmux_shim_set_energy_saver(int enabled, const char* exempt_scheme) {
  return R().SetEnergySaver(enabled, exempt_scheme);
}

// Chromium tracing in host mode (cmux_cef_shim.h; task p09-observability-104): the host's
// Chromium records, and its recording ring with it, through TRACE_START and TRACE_STOP
// (ChromiumHost/src/host_tracing.h). Main thread, as every export of this dylib; each callback
// runs once on the main thread.
CMUX_SHIM_EXPORT int cmux_cef_begin_tracing(const char* categories, cmux_cef_trace_started_fn started, void* ctx) {
  return R().BeginTracing(categories, started, ctx);
}

CMUX_SHIM_EXPORT int cmux_cef_end_tracing(const char* path, cmux_cef_trace_written_fn written, void* ctx) {
  return R().EndTracing(path, written, ctx);
}

// Chromium's trace clock is base::TimeTicks, CLOCK_UPTIME_RAW on macOS: the host's and this
// process's are the same clock, so it is read here, with no round trip.
CMUX_SHIM_EXPORT int64_t cmux_cef_now_trace_us(void) {
#if defined(__APPLE__)
  return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000);
#else
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return static_cast<int64_t>(now.tv_sec) * 1000000 + now.tv_nsec / 1000;
#endif
}

// Per-tab attribution is in-process only: a tab's renderer is the Chromium Host's child, which the
// app does not sample, so there is no pid here. Host mode is task p14-energy-124a.
CMUX_SHIM_EXPORT int cmux_shim_renderer_pid(int browser_id) {
  (void)browser_id;
  return 0;
}

// Memory per hidden workspace is in-process only for the same reason: the renderers are the Chromium
// Host's children, so the app finds no pid for them and counts the sample unclear (p09-observability-061).
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
