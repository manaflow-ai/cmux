// The Chromium Host's side of the control channel
// (plans/cmux-next/chrome-parity/p01-process.md 3.1-3.2):
// every message from cmux becomes one call of the real shim
// (CEFShim/src/shim_*.mm, linked into the host) through the generated
// host_dispatch.inc, and every shim event goes back as one EVENT, after the
// MIRROR values it refreshes. Chrome's browser process runs a Mojo receiver
// the same way: a generated stub per interface method
// (mojo/public/tools/bindings/generators/cpp_templates/interface_definition.tmpl)
// on the thread that owns the object, bad messages ending the peer
// (content/browser/bad_message.cc).
//
// Messages cmux sends (op = a generated op id, chromium_host_control.h framing,
// fields as chromium_host_tlv.h; the remote shim, ../client/remote_shim.mm):
//   kOpHello (first)                            str kWireID, str kShimAbiID: another
//                                              generation of the op table is a bad message
//   a post/view/async/mint/policy/preinit op   its arguments; token != 0 is acked
//                                              (kOpAck) or answered (kOpReply) after the call
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
//   kOpTextInputWatch                           i32 browser, i32 watch: text input
//                                              pushes for the browser start or stop;
//                                              answered with the fork's result
//                                              (host_text_input.h)
//   kOpPageResize                               a page view's size and its fence seq
//                                              (host_resize.h); a fenced one is
//                                              answered with i32 joined
//   kOpTextInputStats                          no fields: answered with the text
//                                              input push counters (host_text_input.h)
//   kOpEnergySaver                              the app's Energy Saver: i32 version, i32 enabled,
//                                              str exempt scheme (host_energy_saver.h); the
//                                              host's shim applies it after initialize, and a
//                                              token is answered with i32 its result
//   kOpGeometryStats                            no fields: answered with GeometryStats as
//                                              i64 frames, applied, unchanged, unplaced
//                                              (chromium-host-bench.py geometry row)
//   kOpBrowserSetLayerHosting                   the generated case's fields and reply; the
//                                              host also detaches the page window whose
//                                              layers it hosts, and answers 0 (a refused
//                                              hosting) when the fork refuses to detach it
//                                              (HandleLayerHosting)
//   kOpBrowserSetPageVisibility                 the generated case; the host also keeps
//                                              the value (KeepPageVisibility) and applies
//                                              it when it detaches the page window, and
//                                              holds its App Nap activity while a page is
//                                              shown (host_page_activity.h)
//   kOpProviderLink                             the browser host's provider socket and the
//                                              relay credential (host_provider_link.h):
// the host dials its own link
//                                              and relays the raw DevTools of the pages the
//                                              browser host attaches, never through cmux
//   kOpBrowserAccessibilityToken               the generated case; for a browser cmux
//                                              minted whose creation has not come, held
//                                              and run once its AFTER_CREATED went out
//                                              (task 049) and after the ack of the op whose
//                                              call created it
//   kOpBrowserSetPageDisplay                    the generated case (the fork places the
//                                              detached page window on cmux's display, so
//                                              its begin-frames, scale and color space are
//                                              that display's, task 221); held as
//                                              kOpBrowserAccessibilityToken is, the newest
//                                              one only
//   kOpSetColorChooserHandler,                  i32 installed (host_choosers.h): the host
//   kOpSetDeviceChooserHandler,                 installs its own handler in its shim while
//   kOpSetDesktopMediaHandler                   cmux has one set (from initialize on) and
//                                              pushes its events (task 228)
//   kOpSetLockHandler                           i32 installed (host_locks.h, task 229): the
//                                              host's own lock handler goes into the fork
//                                              or out of it once initialize returned; a
//                                              host whose fork lacks it changes nothing
//   kOpPasswordReveal                           str profile_cache_path, str id under
//                                              a token: cmux_shim_password_reveal,
//                                              whose done becomes the token's REPLY
// Every preinit op comes before kOpInitialize (the remote shim queues them,
// task 014); everything else after it.
//
// Messages the host sends:
//   kOpHello   str kWireID, StrList of the optional exports its shim defines
//              (and kEnergySaverHelloName when its fork has the saver);
//              once, after the MIRRORs whose only refresh is attach
//   kOpMirror  i32 mirror op, bytes key (EncodeFields), then bytes value
//              (EncodeFields), or no value: cmux forgets the key
//   kOpEvent   EncodeEvent's fields, after the MIRRORs the event refreshes
//   kOpAck     reply flag, token: the op ran
//   kOpReply   reply flag, token, the op's result and out-parameters; for a
//              password reveal one bytes field, the password, or no field when
//              the shim found none (or 64 reveals wait already).
//              That REPLY is the only place the password crosses:
//              no log, trace or counter here names its fields.
//   kOpTextInputState  a watched browser's text input state, at most once per
//              display frame (host_text_input.h)
//   kOpEvent   CMUX_SHIM_COLOR_CHOOSER, _DEVICE_CHOOSER, _DESKTOP_MEDIA: an
//              installed chooser handler's event, the fork's struct as s1's
//              bytes (EncodePayloadEvent, host_choosers.h)
//   kOpEvent   CMUX_SHIM_HELPER_EXIT: one of the host's helpers ended
//              (host_helper_exits.h)
//   kOpEvent   CMUX_SHIM_WHEEL_ACK: the fork's ack of one of a page's wheels,
//              with that wheel's input seq (host_wheel_ack.h); the HELLO lists
//              kWheelAcksHelloName when the fork has the handler
//   kOpHostHang, kOpInputDispatched  the UI thread's hangs and the input it
//              dispatched (host_hang_watcher.h); the HELLO lists
//              kHangWatchHelloName when the host sends them
//   kOpEvent   CMUX_SHIM_LOCK: one call of the fork's lock delegate while
//              cmux's handler is installed (host_locks.h); the HELLO lists
//              kLocksHelloName when the fork has the delegate
//
// Everything here runs on the host's main thread (Chromium's UI thread), so
// it holds no lock (p01-process section 4, rule 1).
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <list>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "chromium_host_control.h"
#include "chromium_host_tlv.h"
#include "chromium_host_wire.h"
#include "host_choosers.h"
#include "host_energy_saver.h"
#include "host_helper_exits.h"
#include "host_locks.h"
#include "host_mirror.h"
#include "host_page_activity.h"
#include "host_provider_link.h"
#include "host_resize.h"
#include "host_window_request_ids.h"
#include "host_text_input.h"
#include "host_wheel_ack.h"

namespace cmux_host {

using TlvWriter = control::TlvWriter;
using TlvReader = control::TlvReader;

// Next to kOpTextInputStats (host_text_input.h): not in the generated op table.
inline constexpr uint16_t kOpGeometryStats = 0x8009;

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

// A page view's place: cmux's ChromiumHostPageView in screen points
// (AppKit's bottom left origin), as a kGeometry frame carries it
// (chromium_host_wire.h). The scale is cmux's window's; the host's window
// takes the scale of the screen this places it on.
struct PageGeometry {
  int32_t width = 0;
  int32_t height = 0;
  int32_t screen_x = 0;
  int32_t screen_y = 0;
  int32_t scale_milli = 0;
  friend bool operator==(const PageGeometry&, const PageGeometry&) = default;
};

// A kGeometry frame's place (a page is at least 1 x 1 point); nullopt for
// every other kind.
std::optional<PageGeometry> PageGeometryOf(const Header& frame);

// The host's views behind cmux's page view tokens (ChromiumHostPageView in
// cmux): the parent views of create_window, devtools_set_placement and
// popup_window_attach.
class PageViews {
 public:
  virtual ~PageViews() = default;
  // The view (NSView*) for `token`, made on first use.
  virtual void* Open(uint64_t token) = 0;
  virtual void Close(uint64_t token) = 0;
  // `token`'s view takes `geometry`. HostContext calls it only for an open
  // view and only when the geometry differs from the last one it placed.
  virtual void Place(uint64_t token, const PageGeometry& geometry) = 0;
  // An open view's size in points (kOpPageResize); nothing when it is that size.
  virtual void Resize(uint64_t token, int32_t width, int32_t height) {
    (void)token;
    (void)width;
    (void)height;
  }
};

// Each view fills a click-through window of the host that is never ordered
// in: Chromium's page window under it is detached (HandleLayerHosting) and
// its pixels show only in cmux, through the layer hosting context
// (host_page_views.mm).
class HostPageViews final : public PageViews {
 public:
  HostPageViews() = default;
  HostPageViews(const HostPageViews&) = delete;
  HostPageViews& operator=(const HostPageViews&) = delete;
  ~HostPageViews() override;
  void* Open(uint64_t token) override;
  void Close(uint64_t token) override;
  void Place(uint64_t token, const PageGeometry& geometry) override;
  void Resize(uint64_t token, int32_t width, int32_t height) override;

 private:
  std::unordered_map<uint64_t, void*> windows_;  // NSWindow*, retained
};

class HostContext {
 public:
  using Send = std::function<bool(const control::Message&)>;
  // The address of a symbol of the host's shim, nullptr when it has none
  // (dlsym in the host: the optional exports, fork API symbols the header
  // does not declare yet).
  using Resolve = void* (*)(const char* name);

  // `request_frame` runs the text input flush at the next display frame
  // (TextInputPushes::RequestFrame).
  HostContext(Send send, HostDelegate& delegate, PageViews& views, Resolve resolve,
              TextInputPushes::RequestFrame request_frame = nullptr);
  HostContext(const HostContext&) = delete;
  HostContext& operator=(const HostContext&) = delete;
  // A reveal the shim answers later finds no host and sends nothing.
  ~HostContext();

  // The fork's cmux_set_wheel_ack_handler (host_wheel_ack.h), nullptr when
  // it has none. Before Attach: the HELLO lists kWheelAcksHelloName with it,
  // and Resume installs OnWheelAck through it.
  void SetWheelAckHandler(SetWheelAckHandlerFn set) { set_wheel_ack_handler_ = set; }
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
  // cmux_shim_browser_text_input_watch's fn; ctx is this HostContext and
  // `state` the fork's cmux_text_input_state_t.
  static void OnTextInput(void* ctx, int browser_id, const void* state);
  // The fork's wheel ack handler; ctx is this HostContext and `ack` the
  // fork's cmux_wheel_ack_t. Forwards CMUX_SHIM_WHEEL_ACK with the input seq
  // of the browser's oldest unacked wheel (WheelSent).
  static void OnWheelAck(void* ctx, int browser_id, const void* ack);
  // The host's handler in the fork's lock delegate (SetLockHandler); ctx is
  // this HostContext. Forwards CMUX_SHIM_LOCK with cmux's id of the browser.
  static void OnLock(void* ctx, int event, int browser_id, int detail);
  // The shim's chooser handlers the host installs (cmux_shim_set_color_chooser_handler,
  // _set_device_chooser_handler, _set_desktop_media_handler); ctx is this HostContext and
  // `data` the fork's struct of an OPEN or UPDATE. Each forwards the event with its payload.
  static void OnColorChooser(void* ctx, int event, int browser_id, int64_t token, unsigned int color,
                             const void* data);
  static void OnDeviceChooser(void* ctx, int event, int browser_id, int64_t token, const void* data);
  static void OnDesktopMedia(void* ctx, int event, int browser_id, int64_t token, const void* data);
  // The chooser handlers installed in the host's shim now (tests, the bench).
  bool chooser_installed(choosers::Handler handler) const { return chooser_installed_[handler]; }
  // The input dispatch gave Chromium's `chromium_id` the wheel of input seq
  // `seq` through the fork's wheel call (a momentum wheel when `momentum`):
  // the fork's first ack of that browser after the acks of the wheels sent
  // before it answers it.
  void WheelSent(int chromium_id, uint32_t seq, bool momentum) { wheel_acks_.Sent(chromium_id, seq, momentum); }
  // One of the host's helpers ended (HelperExitWatcher, handed to the main
  // thread): CMUX_SHIM_HELPER_EXIT goes to cmux like a shim event, so it
  // waits behind an op being dispatched as every event does.
  void HelperExited(const HelperExit& ended);
  // cmux_shim_password_reveal's done; ctx is the reveal's PasswordReveal.
  static void OnPasswordRevealed(void* ctx, const char* password, size_t length);

  // The interface of the generated host_dispatch.inc.
  int Browser(int32_t client_id);
  void* PageView(uint64_t token);
  void Ack(uint32_t token);
  void Reply(uint32_t token, const TlvWriter& reply);
  // `client_browser`: the op's browser argument as cmux named it (devtools_call keys the shim's
  // message id by it; the generator passes it, task 019).
  void BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser);
  // `minted` names the browser of the next `event_kind` event with `request`
  // (create_window's AFTER_CREATED) when the call returned 1.
  void BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int request, int64_t result);
  // The host shim's function for an optional op, nullptr when it has none.
  void* OptionalExport(uint16_t op) const;
  // A value over the frame bound (shm is task 020) goes out as a forget, so
  // cmux never reads the value it replaced.
  void PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value);
  // No value: cmux's cache drops the key.
  void ForgetMirror(uint16_t op, const TlvWriter& key);
  // A post's `pending_keys` (task 016b): pushes mirror `op` again now, while
  // the op's ACK is still held, for each key cmux can hold that `key`
  // matches (bit i of `wildcards`: parameter i is `*` and absent from `key`),
  // so cmux reads the host's value after the op once the ACK clears its mark.
  void RefreshMirror(uint16_t op, const TlvWriter& key, uint32_t wildcards);

  // Clears the shim's focus and window-request handlers: the shim's embedder-active
  // rule decides focus and cmux's pushed policy windows (InstallPolicy* and Resume).
  void InstallHostPolicies();

  // An input ring frame (the ordered stream's dispatch, tasks 041 and 042):
  // true when it is a page's geometry, which this applied; false for every
  // other kind, the input dispatch's. The frame names the browser cmux
  // created the page view's window with (create_window); the newest geometry
  // of a minted id with no browser yet, whose create_window the ring frame
  // overtook or whose creation has not come, waits for its creation. The page
  // view's window moves or resizes only when the geometry changed (task 053), as Chrome's
  // RenderWidgetHostViewMac sends bounds to the renderer only when they
  // differ (content/browser/renderer_host/render_widget_host_view_mac.mm,
  // OnBoundsInWindowChanged).
  bool PlaceFrame(const Header& frame);
  // Geometry frames in all, and of them those that moved or resized a view,
  // those equal to the view's last geometry, and those of a browser with no
  // page view (a tab cmux did not create with create_window, or a held
  // geometry past the bound).
  struct GeometryStats {
    uint64_t frames = 0;
    uint64_t applied = 0;
    uint64_t unchanged = 0;
    uint64_t unplaced = 0;
  };
  const GeometryStats& geometry_stats() const { return geometry_stats_; }

  const TextInputPushes& text_input() const { return text_input_; }
  const WheelAcks& wheel_acks() const { return wheel_acks_; }

  // Where kOpPageResize's fences go (browser_host_main.mm, before Attach);
  // nullptr resizes with no fence.
  void SetPageResizes(PageResizes* resizes) { resizes_ = resizes; }

  // cmux_shim_set_energy_saver's signature.
  using EnergySaverFn = int (*)(int enabled, const char* exempt_scheme);
  // The host shim's saver when its fork has cmux_cef_set_energy_saver
  // (browser_host_main.mm, before Attach, which then lists
  // kEnergySaverHelloName); nullptr takes kOpEnergySaver and changes nothing.
  void SetEnergySaver(EnergySaverFn energy_saver) { energy_saver_ = energy_saver; }

  // The host watches its UI thread's turns and acks the input it dispatches
  // (host_hang_watcher.h, browser_host_main.mm, before Attach): the HELLO
  // lists kHangWatchHelloName, so cmux arms its busy deadline on the acks.
  void SetHangWatch(bool watching) { hang_watch_ = watching; }

  // The host shim's cmux_shim_set_lock_handler when its fork has the lock
  // delegate (browser_host_main.mm, before Attach, which then lists
  // kLocksHelloName); nullptr takes kOpSetLockHandler and changes nothing.
  void SetLockHandler(SetLockHandlerFn set_lock_handler) { set_lock_handler_ = set_lock_handler; }

  // The provider link (browser_host_main.mm, before Attach, which then lists
  // kProviderLinkHelloName): kOpProviderLink goes to
  // `connect`, and the raw DevTools of a page the link relays go to `relays`,
  // not to cmux (host_provider_link.h). Without it kOpProviderLink changes nothing.
  void SetProviderLink(AgentRelays* relays, std::function<void(const ProviderLinkConfig&)> connect) {
    agent_relays_ = relays;
    connect_provider_link_ = std::move(connect);
  }

  // What the shown page count holds (browser_host_main.mm, before Attach):
  // the count goes to it after each kOpBrowserSetPageVisibility, at each
  // browser's close and once initialize returned; nullptr holds nothing.
  void SetPageShowActivity(PageShowActivity* activity) { page_activity_ = activity; }
  // Chromium windows cmux shows (PageWindowVisibility).
  size_t shown_pages() const { return page_windows_.shown(); }

 private:
  enum class State { kPreinit, kInitializing, kRunning, kEnded };
  struct HeldEvent {
    int kind, browser_id, request;
    int64_t a, b;
    std::string s1, s2;
    // A chooser handler's event: s1's bytes (EncodePayloadEvent) instead of s1 and s2.
    std::optional<std::string> payload;
  };
  // A minted id waiting for the event that names its browser.
  struct PendingBind {
    int32_t minted;
    uint64_t view;  // create_window's parent view token
    std::optional<std::string> profile;  // create_window's profile_cache_path ("" the default)
  };

  // A password reveal waiting for the shim's done.
  struct PasswordReveal {
    HostContext* host;  // nullptr once the host context is gone
    uint32_t token;
  };

  void Handle(control::Message& message);
  bool HandleHello(const control::Message& message);
  void Dispatch(const control::Message& message);
  bool HandleInitialize(const control::Message& message);
  bool HandleTextInputWatch(const control::Message& message);
  // kOpBrowserSetLayerHosting: the shim's call, and then, once the page
  // window's pixels are in the context cmux shows, the fork's detached
  // hosting of that window (set_detached_hosting(1), API 30), so no page
  // window of the host is ever on screen; turning hosting off attaches it
  // first. Answers the context id; when the fork refuses to detach, hosting
  // goes off again and the answer is 0, as for a refused hosting.
  bool HandleLayerHosting(const control::Message& message);
  // kOpBrowserSetPageVisibility, before its generated case: keeps cmux's
  // value for the browser, since the fork takes none until the page window
  // is detached, and keeps it for the browser's
  // Chromium window in page_windows_, so a page that shows has the activity
  // before the fork draws it. False past kMaxPageVisibilities.
  bool KeepPageVisibility(const control::Message& message);
  // After `client`'s event changed HostMirrors' windows: page_windows_
  // follows the tab into its window and drops `window_before` (its window
  // before the event) or `event_window` (a TAB_EVENT's window, else 0) when
  // no tab is left in it.
  void FollowPageWindows(int32_t client, int64_t window_before, int64_t event_window);
  // Hands page_windows_' shown count to page_activity_.
  void UpdatePageActivity();
  // Keeps `geometry` as `client_id`'s newest until its creation; past
  // kMaxPendingBinds held ids it is dropped (unplaced).
  void HoldGeometry(int32_t client_id, const PageGeometry& geometry);
  // `chromium_id`'s page view takes `geometry` when it changed.
  void PlaceBrowser(int chromium_id, const PageGeometry& geometry);
  bool HandlePageResize(const control::Message& message);
  // kOpEnergySaver: false for a malformed op.
  bool HandleEnergySaver(const control::Message& message);
  // kOpSetLockHandler: false for a malformed op.
  bool HandleLockHandler(const control::Message& message);
  // kOpProviderLink: false for a malformed op.
  bool HandleProviderLink(const control::Message& message);
  // cmux's kOpDevtoolsWatchEvents with a provider link: false for a malformed op.
  bool HandleDevToolsWatch(const control::Message& message);
  // Keeps `token`'s size for the next op that opens its view (view_sizes_).
  void RememberViewSize(uint64_t token, int32_t width, int32_t height);
  // Watches `chromium_id`'s text input in the fork: its result (0 refused).
  int ArmTextInputWatch(int chromium_id);
  // True while `client_id` is a minted id whose creation event has not come.
  bool AwaitsCreation(int32_t client_id) const;
  // Holds a page accessibility request or page display of a browser not created yet (true), to
  // run after its creation event (RunHeldForCreation); false: run it now. A newer page display
  // replaces the held one; a peer past the bound is bad.
  bool HoldForCreation(control::Message& message);
  void RunHeldForCreation(int32_t client_id);
  void ReplyResult(uint32_t token, int32_t result);
  void RevealPassword(const control::Message& message);
  void SendRevealed(uint32_t token, const char* password, size_t length);
  void Watch(uint16_t op, const std::vector<control::Field>& key);
  // `payload`: a chooser handler's event, sent with EncodePayloadEvent (s1 and s2 unused).
  void ForwardEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1, const char* s2,
                    const std::string* payload = nullptr);
  // A setter op of a chooser handler (task 228): keeps whether cmux has one and, once
  // initialize returned, installs or removes the host's. False for a malformed op.
  bool HandleChooserHandler(choosers::Handler handler, const control::Message& message);
  // Puts the wanted chooser handlers in the shim (Resume and HandleChooserHandler).
  void ApplyChooserHandlers();
  // An OPEN or UPDATE (with `data`, the fork's struct) or another event of `handler`.
  void ForwardChooserEvent(choosers::Handler handler, int event, int browser_id, int64_t token, int64_t b,
                           const void* data);
  void Refresh(const MirrorEvent& event);
  bool Produce(uint16_t op, const std::vector<control::Field>& key);
  void ProduceAttach(bool only_attach);
  void Bad(const std::string& what);
  void Forget(int32_t client_id, int chromium_id);
  // devtools_set_placement named `token` (0: its own window) for every
  // DevTools of `chromium_id`, Chromium's own opens too (context menu
  // Inspect). The placement stands, as the shim's does in process: its view
  // stays open across DevTools closes until the inspected browser closes
  // (Forget) or a placement naming another view replaces it (task 024).
  void PlaceDevTools(int chromium_id, uint64_t token);
  // Closes `token`'s view unless a browser or a DevTools placement still has it.
  void ReleaseView(uint64_t token);
  void Bind(int32_t client_id, int chromium_id);
  int32_t ClientOf(int chromium_id) const;
  // False when the message did not go out (logged).
  bool Post(control::Message message);

  Send send_;
  HostDelegate& delegate_;
  PageViews& views_;
  State state_ = State::kPreinit;
  bool peer_hello_ = false;  // cmux's HELLO came: every other op must follow it
  // Messages that arrived while initialize runs, or mirror watches before it.
  std::deque<control::Message> waiting_;
  uint32_t initialize_token_ = 0;

  // Inside DispatchOp: events, acks and replies wait until the op returns,
  // so ids it minted are bound first and every MIRROR and EVENT the op
  // caused reaches cmux before its ack (read-your-writes, task 016b).
  bool dispatching_ = false;
  uint64_t dispatching_view_ = 0;      // the page view token the op being dispatched opened
  std::optional<std::string> dispatching_profile_;  // a create_window's profile_cache_path
  std::vector<HeldEvent> held_events_;
  std::vector<control::Message> held_replies_;
  // While Dispatch forwards held_events_: still the op's dispatch, so a browser one of them
  // creates runs its held requests (RunHeldForCreation) only after the op's ack.
  bool replaying_held_events_ = false;
  std::vector<int32_t> created_during_replay_;

  // Client ids (minted by cmux, task 019) and Chromium's ids. An id with no
  // entry is the same on both sides.
  std::unordered_map<int32_t, int> chromium_of_;
  std::unordered_map<int, int32_t> client_of_;
  // By (event kind << 32 | request): bounded by kMaxPendingBinds.
  std::unordered_map<uint64_t, PendingBind> pending_binds_;
  // DevTools message ids: (Chromium browser << 32 | the shim's id) -> the minted id.
  std::unordered_map<uint64_t, int32_t> devtools_ids_;
  // The ids minted for the tabs of the window requests the shim decided (task 031).
  WindowRequestTabIds window_request_tabs_;

  // The tab and host mirrors pushed for every open tab (tasks 016 and 017).
  HostMirrors mirrors_;
  // Watched mirror keys by op; a key is the export's arguments.
  std::unordered_map<uint16_t, std::vector<std::vector<control::Field>>> watched_;
  size_t watched_count_ = 0;

  // The optional exports' functions in the host's shim, by op (kOptionalExports).
  std::vector<std::pair<uint16_t, void*>> optional_exports_;

  // Reveals the shim has not answered; each is freed by its done.
  std::unordered_set<PasswordReveal*> reveals_;

  // Open page view tokens, the view each create_window browser has, and the
  // DevTools parent view each inspected browser's placement names.
  std::unordered_set<uint64_t> open_views_;
  std::unordered_map<int, uint64_t> view_of_browser_;
  std::unordered_map<int, uint64_t> devtools_view_of_browser_;
  // The last kOpPageResize size of each page view token, open, not open yet
  // or closed: an op that opens the view, again too, gives it this size. cmux
  // keeps a token for its pane while the pane's browsers come and go, and
  // sends a size only when it changes, so a closed view's size stays. At most
  // kMaxSizedViews: a new token's size takes the place of the least recently
  // resized view that is not open (kMaxPageViews at most are).
  struct ViewSize {
    int32_t width = 0;
    int32_t height = 0;
    std::list<uint64_t>::iterator order;
  };
  std::unordered_map<uint64_t, ViewSize> view_sizes_;
  std::list<uint64_t> view_size_order_;  // least recently resized first

  // Browsers cmux watches the text input of, by Chromium id.
  TextInputPushes text_input_;
  PageResizes* resizes_ = nullptr;
  // The fork's wheel ack handler setter (SetWheelAckHandler) and each page's
  // unacked wheels, by Chromium id.
  SetWheelAckHandlerFn set_wheel_ack_handler_ = nullptr;
  WheelAcks wheel_acks_;
  EnergySaverFn energy_saver_ = nullptr;
  bool hang_watch_ = false;
  SetLockHandlerFn set_lock_handler_ = nullptr;
  // The provider link's relays and its dial (SetProviderLink); nullptr: no link.
  AgentRelays* agent_relays_ = nullptr;
  std::function<void(const ProviderLinkConfig&)> connect_provider_link_;
  // Text input watches of minted ids whose creation has not come, by the
  // minted id: the watch tokens Bind arms and answers. Bounded with
  // pending_binds_ (AwaitsCreation).
  std::unordered_map<int32_t, std::vector<uint32_t>> text_input_awaiting_;
  // Page accessibility requests and page displays of minted ids whose creation has not come, by the minted id.
  // Bounded with pending_binds_ and kMaxHeldPerBrowser (host_dispatch.mm).
  std::unordered_map<int32_t, std::vector<control::Message>> held_for_creation_;

  // The geometry each open page view was last placed at, by token.
  std::unordered_map<uint64_t, PageGeometry> placed_;
  // The newest geometry of minted ids with no browser yet, by the minted id:
  // placed at the creation, dropped at a refused create or a close. Bounded
  // by kMaxPendingBinds (HoldGeometry).
  std::unordered_map<int32_t, PageGeometry> geometry_awaiting_;
  // cmux's last page visibility (cmux_shim_page_visibility_t) by client id,
  // applied again when HandleLayerHosting detaches that browser's page window.
  std::unordered_map<int32_t, int32_t> page_visibility_;
  // The same posts by Chromium window, which the fork applies them to: the
  // shown count page_activity_ holds on.
  PageWindowVisibility page_windows_;
  PageShowActivity* page_activity_ = nullptr;
  GeometryStats geometry_stats_;
  // The chooser handlers cmux has set (its last setter op of each) and those
  // the host's shim has installed now; they differ until initialize returns,
  // or while the fork refuses one (a fork below API 31).
  std::array<bool, choosers::kHandlerCount> chooser_wanted_{};
  std::array<bool, choosers::kHandlerCount> chooser_installed_{};
};

}  // namespace cmux_host
