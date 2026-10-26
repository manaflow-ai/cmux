// The Chromium Host's side of the control channel
// (plans/cmux-next/chrome-parity/p01-process.md 3.1-3.2, task p01-process-013):
// every message from cmux becomes one call of the real shim
// (CEFShim/src/shim_*.mm, linked into the host) through the generated
// host_dispatch.inc, and every shim event goes back as one EVENT, after the
// MIRROR values it refreshes. Chrome's browser process runs a Mojo receiver
// the same way: a generated stub per interface method
// (mojo/public/tools/bindings/generators/cpp_templates/interface_definition.tmpl)
// on the thread that owns the object, bad messages ending the peer
// (content/browser/bad_message.cc).
//
// Messages cmux sends (op = a generated op id, chromium_host_control.h framing):
//   kOpHello first                              str kWireID, str kShimAbiID: another
//                                              generation of the op table, or another
//                                              shim header, ends the host
//   a post/view/async/mint/policy/preinit op   its arguments (chromium_host_tlv.h);
//                                              token != 0 is acked (kOpAck) or
//                                              answered (kOpReply) after the call
//   a mirror op                                 a watch: the key (the export's
//                                              arguments); the host pushes the value
//                                              now and before every event that
//                                              refreshes it, until the browser closes
//                                              (host_mirror.h's tab and host mirrors
//                                              go out with no watch for every open
//                                              tab)
//   kOpInitialize                               cmux_shim_initialize's arguments
//                                              without the function pointers, in
//                                              header order (switches as a str list)
// Every preinit op comes before kOpInitialize (the remote shim queues them,
// task 014); everything else after it.
//
// Messages the host sends:
//   kOpHello   once, before any op is applied and after the mirrors whose only
//              refresh is attach: str kWireID, then the optional exports this
//              host's shim defines (StrList, kOptionalExports' names)
//   kOpEvent   EncodeEvent's fields
//   kOpMirror  i32 mirror op, bytes key, then bytes value (each the fields
//              nested with control::EncodeFields), or no value to forget the key
//   kOpAck     reply flag, token: the op ran
//   kOpReply   reply flag, token, the op's result and out-parameters
//
// Everything here runs on the host's main thread (Chromium's UI thread), so
// it holds no lock (p01-process section 4, rule 1).
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "chromium_host_control.h"
#include "chromium_host_tlv.h"
#include "host_mirror.h"

namespace cmux_host {

using TlvWriter = control::TlvWriter;
using TlvReader = control::TlvReader;

// Zeroes and clears strings that held secrets (password records) once the
// call that read them returned.
void Wipe(std::vector<std::string>& secrets);

// cmux_shim_initialize's arguments as kOpInitialize carries them.
struct InitializeRequest {
  std::string framework_dir;
  std::string main_bundle_path;
  std::string subprocess_path;
  std::string root_cache_path;
  std::optional<std::string> log_file;
  int log_severity = 0;
  std::optional<std::string> locale;
  std::optional<std::string> accept_languages;
  std::vector<std::string> switches;
  uint32_t token = 0;
};

// What the dispatcher asks of the host's main (browser_host_main.mm).
class HostDelegate {
 public:
  virtual ~HostDelegate() = default;
  // kOpInitialize arrived: run cmux_shim_initialize, then Resume().
  virtual void Initialize(InitializeRequest request) = 0;
  // kOpShutdown, or the channel ended: close every browser, end the loop.
  virtual void Quit() = 0;
  // A browser closed (after its BEFORE_CLOSE went out): a quit waits for the last.
  virtual void BrowserClosed() = 0;
  // A message broke the wire's rules: end the host (bad_message).
  virtual void BadMessage(const std::string& what) = 0;
};

// The host's views behind cmux's page view tokens (ChromiumHostPageView in
// cmux): the parent views of create_window, devtools_set_placement and
// popup_window_attach.
class PageViews {
 public:
  virtual ~PageViews() = default;
  // The view (NSView*) for `token`, made on first use.
  virtual void* Open(uint64_t token) = 0;
  virtual void Close(uint64_t token) = 0;
};

// Each view in a transparent, click-through window of the host
// (host_page_views.mm).
class HostPageViews final : public PageViews {
 public:
  HostPageViews() = default;
  HostPageViews(const HostPageViews&) = delete;
  HostPageViews& operator=(const HostPageViews&) = delete;
  ~HostPageViews() override;
  void* Open(uint64_t token) override;
  void Close(uint64_t token) override;

 private:
  std::unordered_map<uint64_t, void*> windows_;  // NSWindow*, retained
};

class HostContext {
 public:
  using Send = std::function<bool(const control::Message&)>;
  // The host shim's symbol for an optional export's name, or NULL (dlsym).
  using Resolve = std::function<void*(const char* name)>;

  HostContext(Send send, HostDelegate& delegate, PageViews& views, Resolve resolve = DefaultResolve);
  HostContext(const HostContext&) = delete;
  HostContext& operator=(const HostContext&) = delete;

  // The mirrors whose only refresh is attach, then the hello. Once, before
  // the first OnMessages; the framework is loaded, CEF not started.
  void Attach();
  // A batch from the channel, in order (UI thread).
  void OnMessages(std::vector<control::Message> messages);
  // cmux_shim_initialize returned 1: acks kOpInitialize, pushes the mirrors
  // that also refresh on attach and runs the messages that waited.
  void Resume();
  // The shim's event_fn; ctx is this HostContext.
  static void OnShimEvent(void* ctx, int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1,
                          const char* s2);
  // The policy handlers installed through InstallPolicy* (initialize's ctx).
  static int OnFocusRequest(void* ctx, int browser_id, int source);
  static int OnWindowRequest(void* ctx, int kind, int disposition, int source_browser_id, int has_bounds, int x,
                             int y, int width, int height, int user_gesture, const char* url,
                             const char* profile_path);

  // The interface of the generated host_dispatch.inc.
  int Browser(int32_t client_id);
  void* PageView(uint64_t token);
  void Ack(uint32_t token);
  void Reply(uint32_t token, const TlvWriter& reply);
  void BindMinted(uint16_t op, int32_t minted, int64_t result);
  void BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int32_t request, int64_t started);
  void* OptionalExport(uint16_t op) const;
  void PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value);

  // Puts the host's own focus and window-request handlers in the shim
  // (InstallPolicy* and Resume).
  void InstallHostPolicies();

  static void* DefaultResolve(const char* name);

 private:
  enum class State { kPreinit, kInitializing, kRunning, kEnded };
  struct HeldEvent {
    int kind, browser_id, request;
    int64_t a, b;
    std::string s1, s2;
  };
  // A create_window cmux sent, until its AFTER_CREATED(request).
  struct PendingCreate {
    int32_t minted;
    uint64_t view;
    std::string profile;  // profile_cache_path; "" for the default profile
  };

  void Handle(control::Message& message);
  void Dispatch(const control::Message& message);
  bool HandleInitialize(const control::Message& message);
  bool HandleHello(const control::Message& message);
  void Watch(uint16_t op, const std::vector<control::Field>& key);
  void ForwardEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1, const char* s2);
  void Refresh(const MirrorEvent& event);
  bool Produce(uint16_t op, const std::vector<control::Field>& key);
  void ProduceAttach(bool only_attach);
  void Bad(const std::string& what);
  void Forget(int32_t client_id, int chromium_id);
  void Bind(int32_t client_id, int chromium_id);
  int32_t ClientOf(int chromium_id) const;
  void Post(control::Message message);

  Send send_;
  HostDelegate& delegate_;
  PageViews& views_;
  Resolve resolve_;
  State state_ = State::kPreinit;
  bool hello_ = false;  // cmux's HELLO arrived and matched
  // kOptionalExports resolved in this host's shim, by op (Attach).
  std::unordered_map<uint16_t, void*> optional_exports_;
  // Messages that arrived while initialize runs, or mirror watches before it.
  std::deque<control::Message> waiting_;
  uint32_t initialize_token_ = 0;

  // Inside DispatchOp: events, acks and replies wait until the op returns,
  // so ids it minted are bound first and every MIRROR and EVENT the op
  // caused reaches cmux before its ack (read-your-writes, task 016b).
  bool dispatching_ = false;
  uint16_t dispatching_op_ = 0;
  int32_t devtools_call_browser_ = 0;  // the client browser of the devtools_call being dispatched
  std::vector<HeldEvent> held_events_;
  std::vector<control::Message> held_replies_;

  // Client ids (minted by cmux, task 019) and Chromium's ids. An id with no
  // entry is the same on both sides.
  std::unordered_map<int32_t, int> chromium_of_;
  std::unordered_map<int, int32_t> client_of_;
  std::unordered_map<int, PendingCreate> pending_creates_;  // by create_window's request
  // DevTools message ids: (Chromium browser << 32 | the shim's id) -> the minted id.
  std::unordered_map<uint64_t, int32_t> devtools_ids_;

  // The tab and host mirrors pushed for every open tab (tasks 016 and 017).
  HostMirrors mirrors_;
  // Watched mirror keys by op; a key is the export's arguments.
  std::unordered_map<uint16_t, std::vector<std::vector<control::Field>>> watched_;
  size_t watched_count_ = 0;

  // Open page view tokens, and the view each create_window browser has.
  std::unordered_set<uint64_t> open_views_;
  std::unordered_map<int, uint64_t> view_of_browser_;
};

}  // namespace cmux_host
