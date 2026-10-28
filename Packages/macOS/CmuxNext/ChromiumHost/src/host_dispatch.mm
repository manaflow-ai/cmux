// The Chromium Host's dispatcher (host_dispatch.h): one generated case per
// shim export (generated/host_dispatch.inc), the id maps, the watched mirror
// keys and the host's window-request policy. No AppKit: the page
// views are behind PageViews (host_page_views.mm).

#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <iterator>
#include <memory>
#include <utility>

#include "chromium_host_input_ring.h"
#include "chromium_host_mint.h"
#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_hang_watcher.h"

namespace cmux_host {

std::optional<PageGeometry> PageGeometryOf(const Header& frame) {
  if (frame.kind != kGeometry) return std::nullopt;
  PageGeometry geometry;
  geometry.width = std::max(1, frame.v[0]);
  geometry.height = std::max(1, frame.v[1]);
  geometry.screen_x = frame.v[2];
  geometry.screen_y = frame.v[3];
  geometry.scale_milli = frame.v[4];
  return geometry;
}

void Wipe(std::vector<std::string>& secrets) {
  for (std::string& secret : secrets) {
    volatile char* bytes = secret.data();  // volatile: the stores are not dead to the optimizer
    for (size_t i = 0; i < secret.size(); ++i) bytes[i] = 0;
    secret.clear();
  }
}

}  // namespace cmux_host

#include "generated/host_dispatch.inc"

namespace cmux_host {
namespace {

// Watched mirror keys in all; a peer past it breaks the wire's bounds.
constexpr size_t kMaxWatchedKeys = 16384;
// Page view tokens open at once.
constexpr size_t kMaxPageViews = 4096;
// Page view sizes kept (HostContext::view_sizes_): room for every open view
// and as many closed ones.
constexpr size_t kMaxSizedViews = 2 * kMaxPageViews;
// create_window and create_placeholder_window calls whose AFTER_CREATED has
// not come yet.
constexpr size_t kMaxPendingBinds = 4096;
// Requests held for one browser's creation: cmux asks for the page's accessibility once per page,
// window and context its page view shows, and holds one page display (the newest).
constexpr size_t kMaxHeldPerBrowser = 16;
// Browsers whose page visibility the host keeps (one per pane cmux shows; a
// browser's entry goes at its BEFORE_CLOSE).
constexpr size_t kMaxPageVisibilities = 65536;
// Password reveals the shim has not answered. Past it a reveal is answered as
// not found: cmux is trusted, and a stalled profile store must not end the host.
constexpr size_t kMaxPendingReveals = 64;

bool IsMirrorOp(uint16_t op) {
  for (const MirrorRefresh& row : kMirrorRefreshes) {
    if (row.op != 0 && row.op == op) return true;
  }
  return false;
}

// True when every refresh of the mirror is the attach pseudo event: a fork
// capability, read once at the hello. Others (counts) also refresh on attach
// but read CEF state, so they wait until initialize returned.
bool OnlyAttach(uint16_t op) {
  bool any = false;
  for (const MirrorRefresh& row : kMirrorRefreshes) {
    if (row.op != op) continue;
    if (row.kind != kEventAttach) return false;
    any = true;
  }
  return any;
}

// The chooser handler whose setter op `op` is (host_choosers.h); nullopt for any other op.
std::optional<choosers::Handler> ChooserHandlerOf(uint16_t op) {
  switch (op) {
    case kOpSetColorChooserHandler:
      return choosers::kColor;
    case kOpSetDeviceChooserHandler:
      return choosers::kDevice;
    case kOpSetDesktopMediaHandler:
      return choosers::kDesktopMedia;
    default:
      return std::nullopt;
  }
}

uint64_t BindKey(int event_kind, int request) {
  return (static_cast<uint64_t>(static_cast<uint32_t>(event_kind)) << 32) | static_cast<uint32_t>(request);
}

// The frame body `fields` make (chromium_host_control.h): a field header and
// its payload each.
size_t BodySize(const std::vector<control::Field>& fields) {
  size_t size = 0;
  for (const control::Field& field : fields) {
    const size_t payload = field.type == control::Type::kI32                                         ? 4
                           : field.type == control::Type::kI64 || field.type == control::Type::kF64 ? 8
                                                                                                     : field.bytes.size();
    size += control::kFieldHeaderSize + payload;
  }
  return size;
}

uint64_t DevToolsKey(int chromium_id, int32_t message_id) {
  return (static_cast<uint64_t>(static_cast<uint32_t>(chromium_id)) << 32) | static_cast<uint32_t>(message_id);
}

control::Message MessageOf(uint16_t op, bool reply, uint32_t token, std::vector<control::Field> fields) {
  control::Message message;
  message.op = op;
  message.reply = reply;
  message.token = token;
  message.fields = std::move(fields);
  return message;
}

}  // namespace

HostContext::HostContext(Send send, HostDelegate& delegate, PageViews& views, Resolve resolve,
                         TextInputPushes::RequestFrame request_frame)
    : send_(std::move(send)),
      delegate_(delegate),
      views_(views),
      text_input_(std::move(request_frame), [this](int browser, const TextInputState& state) {
        return Post(MessageOf(kOpTextInputState, false, 0, EncodeTextInputState(ClientOf(browser), state)));
      }) {
  for (const auto& entry : kOptionalExports) {
    if (void* fn = resolve ? resolve(entry.name) : nullptr) optional_exports_.emplace_back(entry.op, fn);
  }
}

HostContext::~HostContext() {
  for (PasswordReveal* reveal : reveals_) reveal->host = nullptr;
}

void HostContext::Attach() {
  ProduceAttach(true);
  std::vector<const char*> exports;
  for (const auto& entry : kOptionalExports) {
    if (OptionalExport(entry.op)) exports.push_back(entry.name);
  }
  // Not an export: the host acks every wheel of a gesture (OnWheelAck), so cmux asks the page nothing.
  if (set_wheel_ack_handler_) exports.push_back(kWheelAcksHelloName);
  if (energy_saver_) exports.push_back(kEnergySaverHelloName);
  // Not an export: the host acks dispatched input and reports its UI hangs (host_hang_watcher.h).
  if (hang_watch_) exports.push_back(hang::kHangWatchHelloName);
  if (set_lock_handler_) exports.push_back(kLocksHelloName);
  if (agent_relays_) exports.push_back(kProviderLinkHelloName);
  TlvWriter hello;
  hello.Str(kWireID);
  hello.StrList(exports.data(), static_cast<int>(exports.size()));
  Post(MessageOf(control::kOpHello, false, 0, hello.Take()));
}

void* HostContext::OptionalExport(uint16_t op) const {
  for (const auto& [optional_op, fn] : optional_exports_) {
    if (optional_op == op) return fn;
  }
  return nullptr;
}

void HostContext::ProduceAttach(bool only_attach) {
  ForEachMirrorRefreshedBy(kEventAttach, -1, [&](uint16_t op) {
    if (OnlyAttach(op) == only_attach) Watch(op, {});
  });
}

void HostContext::OnMessages(std::vector<control::Message> messages) {
  for (control::Message& message : messages) {
    if (state_ == State::kEnded) break;
    Handle(message);
  }
}

void HostContext::Resume() {
  if (state_ != State::kInitializing) return;
  state_ = State::kRunning;
  InstallHostPolicies();
  ApplyChooserHandlers();
  if (set_wheel_ack_handler_ && !set_wheel_ack_handler_(&HostContext::OnWheelAck, this)) {
    // The HELLO said acks come: the swipe waits for them, so a refusal is the fork's bug, logged.
    fprintf(stderr, "cmux-chromium-host: the fork refused the wheel ack handler\n");
  }
  Ack(initialize_token_);
  ProduceAttach(false);
  while (!waiting_.empty() && state_ == State::kRunning) {
    control::Message message = std::move(waiting_.front());
    waiting_.pop_front();
    Handle(message);
  }
  // Held since the start: with no page shown now, the host may nap.
  UpdatePageActivity();
}

void HostContext::Handle(control::Message& message) {
  // No op takes descriptors yet (shm payloads are task 020).
  for (int fd : message.fds) close(fd);
  message.fds.clear();
  if (message.reply) return Bad("a reply frame from cmux");
  if (!peer_hello_) {
    if (message.op != control::kOpHello || !HandleHello(message)) Bad("no hello of this wire first");
    return;
  }
  if (message.op == control::kOpHello) return Bad("a second hello");
  if (const std::optional<choosers::Handler> handler = ChooserHandlerOf(message.op); handler && state_ != State::kEnded) {
    if (!HandleChooserHandler(*handler, message)) Bad("a malformed chooser handler op");
    return;
  }
  switch (state_) {
    case State::kEnded:
      return;
    case State::kInitializing:
      waiting_.push_back(std::move(message));
      return;
    case State::kPreinit:
      if (message.op == kOpInitialize) {
        if (!HandleInitialize(message)) Bad("a malformed initialize");
      } else if (IsMirrorOp(message.op) || message.op == kOpPageResize || message.op == kOpEnergySaver ||
                 message.op == kOpSetLockHandler || message.op == kOpProviderLink) {
        waiting_.push_back(std::move(message));  // CEF state: read once initialize returned
      } else {
        Dispatch(message);  // a preinit op: the remote shim sends nothing else before initialize
      }
      return;
    case State::kRunning:
      if (message.op == kOpInitialize) return Bad("a second initialize");
      if (message.op == kOpTextInputWatch) {
        if (!HandleTextInputWatch(message)) Bad("a malformed text input watch");
        return;
      }
      if (message.op == kOpTextInputStats) {
        if (!message.fields.empty()) return Bad("a malformed text input stats request");
        const TextInputPushes::Stats& stats = text_input_.stats();
        TlvWriter reply;
        for (uint64_t value : {stats.changes, stats.pushes, stats.frames, stats.unsent,
                               static_cast<uint64_t>(text_input_.watches())}) {
          reply.I64(static_cast<int64_t>(value));
        }
        Reply(message.token, reply);
        return;
      }
      if (message.op == kOpGeometryStats) {
        if (!message.fields.empty()) return Bad("a malformed geometry stats request");
        TlvWriter reply;
        for (uint64_t value : {geometry_stats_.frames, geometry_stats_.applied, geometry_stats_.unchanged,
                               geometry_stats_.unplaced}) {
          reply.I64(static_cast<int64_t>(value));
        }
        Reply(message.token, reply);
        return;
      }
      if (message.op == kOpBrowserSetLayerHosting) {
        if (!HandleLayerHosting(message)) Bad("a malformed layer hosting op");
        return;
      }
      if (message.op == kOpPageResize) {
        if (!HandlePageResize(message)) Bad("a malformed page resize");
        return;
      }
      if (message.op == kOpEnergySaver) {
        if (!HandleEnergySaver(message)) Bad("a malformed energy saver");
        return;
      }
      if (message.op == kOpSetLockHandler) {
        if (!HandleLockHandler(message)) Bad("a malformed lock handler");
        return;
      }
      if (message.op == kOpProviderLink) {
        if (!HandleProviderLink(message)) Bad("a malformed provider link");
        return;
      }
      if (message.op == kOpDevtoolsWatchEvents && agent_relays_) {
        if (!HandleDevToolsWatch(message)) Bad("a malformed devtools watch");
        return;
      }
      if (IsMirrorOp(message.op)) return Watch(message.op, message.fields);
      if ((message.op == kOpBrowserAccessibilityToken || message.op == kOpBrowserSetPageDisplay) &&
          HoldForCreation(message)) {
        return;
      }
      if (message.op == kOpBrowserSetPageVisibility && !KeepPageVisibility(message)) {
        return Bad("too many page visibilities");
      }
      Dispatch(message);
      return;
  }
}

bool HostContext::HoldForCreation(control::Message& message) {
  TlvReader peek(message.fields);
  const int32_t client = peek.I32();
  // A malformed op is the generated case's to refuse.
  if (!peek.ok() || !AwaitsCreation(client)) return false;
  std::vector<control::Message>& held = held_for_creation_[client];
  // A page display replaces the one held before it: only the newest display places the page window
  // (task 221), as only the newest geometry waits (HoldGeometry).
  if (message.op == kOpBrowserSetPageDisplay) {
    auto older = std::find_if(held.begin(), held.end(),
                              [](const control::Message& m) { return m.op == kOpBrowserSetPageDisplay; });
    if (older != held.end()) {
      *older = std::move(message);
      return true;
    }
  }
  if (held.size() >= kMaxHeldPerBrowser) {
    Bad("too many requests waiting for a browser's creation");
    return true;
  }
  held.push_back(std::move(message));
  return true;
}

void HostContext::RunHeldForCreation(int32_t client_id) {
  auto held = held_for_creation_.find(client_id);
  if (held == held_for_creation_.end()) return;
  std::vector<control::Message> messages = std::move(held->second);
  held_for_creation_.erase(held);
  for (const control::Message& message : messages) {
    if (state_ != State::kRunning) return;
    Dispatch(message);
  }
}

// The fence joins the browser's next commit before the view's frame changes,
// in this turn (host_resize.h). A view not open yet is not made here: it
// takes the size when an op opens it (PageView).
bool HostContext::HandlePageResize(const control::Message& message) {
  const std::optional<PageResize> resize = DecodePageResize(message.fields);
  if (!resize) return false;
  RememberViewSize(resize->view, resize->width, resize->height);
  const int chromium_id = AwaitsCreation(resize->browser) ? 0 : Browser(resize->browser);
  auto change_frame = [&] {
    if (open_views_.count(resize->view)) views_.Resize(resize->view, resize->width, resize->height);
  };
  bool joined = false;
  if (resizes_) {
    joined = resizes_->Apply(*resize, chromium_id, change_frame);
  } else {
    change_frame();
  }
  if (message.token != 0) {
    TlvWriter reply;
    reply.I32(joined ? 1 : 0);
    Reply(message.token, reply);
  }
  return true;
}

// The shim's call runs after CefInitialize returned (it is on the main
// thread, as cmux_shim_set_energy_saver requires): a message from before
// waited in waiting_.
bool HostContext::HandleEnergySaver(const control::Message& message) {
  const std::optional<EnergySaver> saver = DecodeEnergySaver(message.fields);
  if (!saver) return false;
  const int result = energy_saver_ ? energy_saver_(saver->enabled ? 1 : 0,
                                                   saver->exempt_scheme ? saver->exempt_scheme->c_str() : nullptr)
                                   : 0;
  if (message.token != 0) {
    TlvWriter reply;
    reply.I32(result);
    Reply(message.token, reply);
  }
  return true;
}

// Dials (or ends) the host's own provider link; a host built without one
// takes the op and changes nothing. Applied after initialize: the relays it
// carries send to Chromium.
bool HostContext::HandleProviderLink(const control::Message& message) {
  const std::optional<ProviderLinkConfig> config = DecodeProviderLink(message.fields);
  if (!config) return false;
  if (connect_provider_link_) connect_provider_link_(*config);
  if (message.token != 0) Ack(message.token);
  return true;
}

// The page's watch is cmux's or the link's: Chromium keeps it on while
// either wants it (AgentRelays::CmuxWatch), so a relay's events never stop
// because cmux stopped watching, and cmux's never start because of a relay.
bool HostContext::HandleDevToolsWatch(const control::Message& message) {
  TlvReader r(message.fields);
  const int32_t client = r.I32();
  const int32_t enabled = r.I32();
  if (!r.ok() || !r.AtEnd()) return false;
  cmux_shim_devtools_watch_events(Browser(client), agent_relays_->CmuxWatch(client, enabled != 0));
  Ack(message.token);
  return true;
}

// The fork's delegate calls OnLock on the UI thread, this one; a fork that
// lacks it (no set_lock_handler_) takes nothing, and cmux's remote shim never
// sends the op to such a host (its HELLO lists no kLocksHelloName).
bool HostContext::HandleLockHandler(const control::Message& message) {
  const std::optional<bool> installed = DecodeLockHandler(message.fields);
  if (!installed) return false;
  if (set_lock_handler_ && !set_lock_handler_(*installed ? &HostContext::OnLock : nullptr, *installed ? this : nullptr)) {
    fprintf(stderr, "cmux-chromium-host: the fork refused the lock handler\n");
  }
  Ack(message.token);
  return true;
}

void HostContext::RememberViewSize(uint64_t token, int32_t width, int32_t height) {
  if (auto found = view_sizes_.find(token); found != view_sizes_.end()) {
    view_size_order_.splice(view_size_order_.end(), view_size_order_, found->second.order);
    found->second.width = width;
    found->second.height = height;
    return;
  }
  if (view_sizes_.size() >= kMaxSizedViews) {
    // At most kMaxPageViews of them are open: a closed one is there to go.
    for (auto oldest = view_size_order_.begin(); oldest != view_size_order_.end(); ++oldest) {
      if (open_views_.count(*oldest)) continue;
      view_sizes_.erase(*oldest);
      view_size_order_.erase(oldest);
      break;
    }
  }
  view_size_order_.push_back(token);
  view_sizes_[token] = {width, height, std::prev(view_size_order_.end())};
}

bool HostContext::HandleHello(const control::Message& message) {
  TlvReader r(message.fields);
  const std::optional<std::string> wire = r.Str();
  const std::optional<std::string> abi = r.Str();
  if (!r.ok() || !r.AtEnd() || wire != std::optional<std::string>(kWireID) ||
      abi != std::optional<std::string>(kShimAbiID)) {
    return false;
  }
  peer_hello_ = true;
  return true;
}

bool HostContext::HandleInitialize(const control::Message& message) {
  TlvReader r(message.fields);
  InitializeRequest request;
  request.framework_dir = r.Str().value_or("");
  request.main_bundle_path = r.Str().value_or("");
  request.subprocess_path = r.Str().value_or("");
  request.root_cache_path = r.Str().value_or("");
  request.log_file = r.Str();
  request.log_severity = r.I32();
  request.locale = r.Str();
  request.accept_languages = r.Str();
  request.switches = r.StrList();
  if (!r.ok() || !r.AtEnd()) return false;
  request.token = message.token;
  initialize_token_ = message.token;
  state_ = State::kInitializing;
  delegate_.Initialize(std::move(request));
  return true;
}

bool HostContext::HandleTextInputWatch(const control::Message& message) {
  TlvReader r(message.fields);
  const int32_t client = r.I32();
  const int32_t watch = r.I32();
  if (!r.ok() || !r.AtEnd() || (watch != 0 && watch != 1)) return false;
  auto awaiting = text_input_awaiting_.find(client);
  if (watch) {
    if (awaiting != text_input_awaiting_.end() || AwaitsCreation(client)) {
      text_input_awaiting_[client].push_back(message.token);  // Bind arms and answers it
    } else {
      ReplyResult(message.token, ArmTextInputWatch(Browser(client)));
    }
    return true;
  }
  if (awaiting != text_input_awaiting_.end()) {
    // The watch never reached the fork: it answers 0, the unwatch 1.
    for (uint32_t token : awaiting->second) ReplyResult(token, 0);
    text_input_awaiting_.erase(awaiting);
    ReplyResult(message.token, 1);
    return true;
  }
  const int browser = Browser(client);
  text_input_.Forget(browser);
  ReplyResult(message.token, cmux_shim_browser_text_input_watch(browser, nullptr, nullptr));
  return true;
}

bool HostContext::HandleLayerHosting(const control::Message& message) {
  TlvReader r(message.fields);
  const int32_t client = r.I32();
  const int32_t enabled = r.I32();
  if (!r.ok() || !r.AtEnd()) return false;
  const int browser = Browser(client);
  if (!enabled) cmux_shim_browser_set_detached_hosting(browser, 0);
  unsigned int context = cmux_shim_browser_set_layer_hosting(browser, enabled);
  if (enabled && context != 0 && !cmux_shim_browser_set_detached_hosting(browser, 1)) {
    // The page window is never ordered in (HostPageViews), so an attached one is hidden to the
    // fork's tracker: hosting it would show a blank or frozen page. A refused hosting instead.
    fprintf(stderr, "cmux-chromium-host: the fork did not detach browser %d's page window\n", browser);
    cmux_shim_browser_set_layer_hosting(browser, 0);
    context = 0;
  }
  // The fork took no visibility before the detach: cmux's last one applies now.
  auto visibility = page_visibility_.find(client);
  if (enabled && context != 0 && visibility != page_visibility_.end()) {
    cmux_shim_browser_set_page_visibility(browser, visibility->second);
  }
  TlvWriter reply;
  reply.U32(context);
  Reply(message.token, reply);
  return true;
}

bool HostContext::KeepPageVisibility(const control::Message& message) {
  TlvReader peek(message.fields);
  const int32_t client = peek.I32();
  const int32_t visibility = peek.I32();
  // A malformed op is the generated case's to refuse.
  if (!peek.ok() || !peek.AtEnd()) return true;
  if (!page_visibility_.count(client) && page_visibility_.size() >= kMaxPageVisibilities) return false;
  page_visibility_[client] = visibility;
  page_windows_.Post(mirrors_.WindowOf(client), client, visibility);
  UpdatePageActivity();
  return true;
}

void HostContext::FollowPageWindows(int32_t client, int64_t window_before, int64_t event_window) {
  if (page_windows_.empty()) return;
  if (const int64_t window = mirrors_.WindowOf(client); window != 0) page_windows_.Placed(client, window);
  for (const int64_t window : {window_before, event_window}) {
    if (window != 0 && !mirrors_.HasTabs(window)) page_windows_.WindowGone(window);
  }
  UpdatePageActivity();
}

void HostContext::UpdatePageActivity() {
  if (page_activity_) page_activity_->SetShownPages(page_windows_.shown());
}

bool HostContext::PlaceFrame(const Header& frame) {
  const std::optional<PageGeometry> geometry = PageGeometryOf(frame);
  if (!geometry) return false;
  ++geometry_stats_.frames;
  if (state_ == State::kEnded) return true;
  const int32_t client = input_ring::BrowserOf(frame);
  // A minted id that names no browser yet: its create_window is still on the control channel
  // (create_window is not an ordered op, so the ring can overtake it) or waits for its creation.
  if (AwaitsCreation(client) || (mint::IsMintedBrowser(client) && !chromium_of_.count(client))) {
    HoldGeometry(client, *geometry);
    return true;
  }
  PlaceBrowser(Browser(client), *geometry);
  return true;
}

void HostContext::HoldGeometry(int32_t client_id, const PageGeometry& geometry) {
  auto held = geometry_awaiting_.find(client_id);
  if (held != geometry_awaiting_.end()) {
    held->second = geometry;  // the newest one; ForwardEvent places it
    return;
  }
  if (geometry_awaiting_.size() >= kMaxPendingBinds) {
    ++geometry_stats_.unplaced;
    return;
  }
  geometry_awaiting_.emplace(client_id, geometry);
}

void HostContext::PlaceBrowser(int chromium_id, const PageGeometry& geometry) {
  auto view = view_of_browser_.find(chromium_id);
  if (view == view_of_browser_.end()) {
    ++geometry_stats_.unplaced;
    return;
  }
  auto [placed, first] = placed_.try_emplace(view->second, geometry);
  if (!first && placed->second == geometry) {
    ++geometry_stats_.unchanged;
    return;
  }
  placed->second = geometry;
  ++geometry_stats_.applied;
  views_.Place(view->second, geometry);
}

int HostContext::ArmTextInputWatch(int chromium_id) {
  // The fork calls OnTextInput at once with the current state: watch first.
  text_input_.Watch(chromium_id);
  const int result = cmux_shim_browser_text_input_watch(chromium_id, &HostContext::OnTextInput, this);
  if (!result) text_input_.Forget(chromium_id);  // an unknown browser, or a fork without the watch
  return result;
}

bool HostContext::AwaitsCreation(int32_t client_id) const {
  for (const auto& [key, pending] : pending_binds_) {
    if (pending.minted == client_id) return true;
  }
  return false;
}

void HostContext::ReplyResult(uint32_t token, int32_t result) {
  TlvWriter reply;
  reply.I32(result);
  Reply(token, reply);
}

void HostContext::OnTextInput(void* ctx, int browser_id, const void* state) {
  auto* host = static_cast<HostContext*>(ctx);
  if (host->state_ == State::kEnded) return;
  TextInputState read;
  // A state the host cannot read is no editable focus: cmux's client then has no marked text.
  if (!ReadForkTextInputState(state, &read)) read = TextInputState{};
  TrimToSelectionContext(&read);
  host->text_input_.Changed(browser_id, std::move(read));
}

void HostContext::OnWheelAck(void* ctx, int browser_id, const void* ack) {
  auto* host = static_cast<HostContext*>(ctx);
  if (host->state_ == State::kEnded) return;
  WheelAck read;
  // An unreadable ack still answers its wheel, so the next ack names the next wheel.
  const bool readable = ReadForkWheelAck(ack, &read);
  const std::optional<WheelAckEvent> event = host->wheel_acks_.Acked(browser_id, readable ? &read : nullptr);
  if (!event) return;
  host->ForwardEvent(kEventWheelAck, browser_id, event->request, event->a, event->b, "", "");
}

void HostContext::OnLock(void* ctx, int event, int browser_id, int detail) {
  auto* host = static_cast<HostContext*>(ctx);
  if (host->state_ == State::kEnded) return;
  host->ForwardEvent(CMUX_SHIM_LOCK, browser_id, event, detail, 0, "", "");
}

bool HostContext::HandleChooserHandler(choosers::Handler handler, const control::Message& message) {
  const std::optional<bool> installed = choosers::ReadInstalled(message.fields);
  if (!installed) return false;
  chooser_wanted_[handler] = *installed;
  // Before initialize the shim has no fork to install in: Resume applies it.
  if (state_ == State::kRunning) ApplyChooserHandlers();
  return true;
}

void HostContext::ApplyChooserHandlers() {
  for (int i = 0; i < choosers::kHandlerCount; ++i) {
    const auto handler = static_cast<choosers::Handler>(i);
    const bool wanted = chooser_wanted_[handler];
    if (wanted == chooser_installed_[handler]) continue;
    void* context = wanted ? this : nullptr;
    int result = 0;
    switch (handler) {
      case choosers::kColor:
        result = cmux_shim_set_color_chooser_handler(wanted ? &HostContext::OnColorChooser : nullptr, context);
        break;
      case choosers::kDevice:
        result = cmux_shim_set_device_chooser_handler(wanted ? &HostContext::OnDeviceChooser : nullptr, context);
        break;
      case choosers::kDesktopMedia:
        result = cmux_shim_set_desktop_media_handler(wanted ? &HostContext::OnDesktopMedia : nullptr, context);
        break;
    }
    if (wanted && !result) {
      // A fork below API 31: Chromium keeps its own chooser, which the host never shows.
      fprintf(stderr, "cmux-chromium-host: the fork refused chooser handler %d\n", i);
      continue;
    }
    // A removal the fork refused still leaves no handler of the host's: its old requests ended.
    chooser_installed_[handler] = wanted;
  }
}

void HostContext::OnColorChooser(void* ctx, int event, int browser_id, int64_t token, unsigned int color,
                                 const void* data) {
  static_cast<HostContext*>(ctx)->ForwardChooserEvent(choosers::kColor, event, browser_id, token, color, data);
}

void HostContext::OnDeviceChooser(void* ctx, int event, int browser_id, int64_t token, const void* data) {
  static_cast<HostContext*>(ctx)->ForwardChooserEvent(choosers::kDevice, event, browser_id, token, 0, data);
}

void HostContext::OnDesktopMedia(void* ctx, int event, int browser_id, int64_t token, const void* data) {
  static_cast<HostContext*>(ctx)->ForwardChooserEvent(choosers::kDesktopMedia, event, browser_id, token, 0, data);
}

void HostContext::ForwardChooserEvent(choosers::Handler handler, int event, int browser_id, int64_t token, int64_t b,
                                      const void* data) {
  if (state_ == State::kEnded) return;
  std::string payload;
  if (event == choosers::OpenEventOf(handler)) {
    bool encoded = false;
    switch (handler) {
      case choosers::kColor:
        encoded = choosers::EncodeColorChooser(data, &payload);
        break;
      case choosers::kDevice:
        encoded = choosers::EncodeDeviceChooser(data, &payload);
        break;
      case choosers::kDesktopMedia:
        encoded = choosers::EncodeDesktopMedia(data, &payload);
        break;
    }
    // Within the bounds an encoding cannot fail; one that did would leave the page waiting.
    if (!encoded) return Bad("a chooser payload over its bounds");
  }
  ForwardEvent(choosers::EventKindOf(handler), browser_id, event, token, b, nullptr, nullptr, &payload);
}

void HostContext::Dispatch(const control::Message& message) {
  if (message.op == kOpPasswordReveal) return RevealPassword(message);  // local class: no generated case
  if (message.op == kOpShutdown) {
    // CefShutdown runs once the loop has ended (browser_host_main.mm), never inside a task.
    Ack(message.token);
    delegate_.Quit();
    return;
  }
  std::optional<std::string> profile;
  if (message.op == kOpCreateWindow) {
    // Header order: minted id, request, parent view, width, height, url,
    // profile_cache_path (NULL: the default profile, "").
    TlvReader peek(message.fields);
    peek.I32();
    peek.I32();
    peek.View();
    peek.I32();
    peek.I32();
    peek.Str();
    std::optional<std::string> path = peek.Str();
    if (peek.ok()) profile = path.value_or(std::string());
  }
  if (message.op == kOpCreatePlaceholderWindow) {
    // Header order: minted id, request, parent view, width, height,
    // profile_cache_path (NULL: the default profile, "").
    TlvReader peek(message.fields);
    peek.I32();
    peek.I32();
    peek.View();
    peek.I32();
    peek.I32();
    std::optional<std::string> path = peek.Str();
    if (peek.ok()) profile = path.value_or(std::string());
  }
  int32_t placed_browser = 0;
  uint64_t placed_view = 0;
  if (message.op == kOpDevtoolsSetPlacement) {
    // Header order: browser, parent view, x, y, width, height.
    TlvReader peek(message.fields);
    placed_browser = peek.I32();
    placed_view = peek.View();
    if (!peek.ok()) placed_browser = 0;
  }
  dispatching_ = true;
  dispatching_view_ = 0;
  dispatching_profile_ = std::move(profile);
  TlvReader r(message.fields);
  const bool ok = DispatchOp(*this, message.op, message.token, r);
  dispatching_ = false;
  dispatching_view_ = 0;
  dispatching_profile_.reset();
  if (ok && placed_browser) PlaceDevTools(Browser(placed_browser), placed_view);
  std::vector<HeldEvent> events;
  events.swap(held_events_);
  replaying_held_events_ = true;
  for (const HeldEvent& e : events) {
    ForwardEvent(e.kind, e.browser_id, e.request, e.a, e.b, e.s1.c_str(), e.s2.c_str(), e.payload ? &*e.payload : nullptr);
  }
  replaying_held_events_ = false;
  std::vector<control::Message> replies;
  replies.swap(held_replies_);
  for (control::Message& reply : replies) Post(std::move(reply));
  if (!ok) Bad("a malformed op " + std::to_string(message.op));
  // Browsers the op's events created run their held requests after the op's ack, each an op of its own.
  std::vector<int32_t> created;
  created.swap(created_during_replay_);
  for (int32_t client : created) RunHeldForCreation(client);
}

// cmux_shim_password_reveal for cmux's local client (remote_shim_local.mm),
// which keeps the done and ctx it was given: the host's own done answers the
// token. As Chrome's PasswordsPrivateDelegate answers a plaintext request
// through its callback, never through a broadcast (chrome/browser/extensions/
// api/passwords_private/passwords_private_delegate_impl.cc).
void HostContext::RevealPassword(const control::Message& message) {
  TlvReader r(message.fields);
  const std::optional<std::string> path = r.Str();
  const std::optional<std::string> id = r.Str();
  if (!r.ok() || !r.AtEnd() || message.token == 0) return Bad("a malformed password reveal");
  if (state_ != State::kRunning) return SendRevealed(message.token, nullptr, 0);  // the shim's 0: not started
  if (reveals_.size() >= kMaxPendingReveals) return SendRevealed(message.token, nullptr, 0);
  auto reveal = std::make_unique<PasswordReveal>(PasswordReveal{this, message.token});
  PasswordReveal* pending = reveal.get();
  reveals_.insert(pending);
  // done runs exactly once when this returns 1, and never when it returns 0.
  const int started = cmux_shim_password_reveal(path ? path->c_str() : nullptr, id ? id->c_str() : nullptr,
                                                &HostContext::OnPasswordRevealed, reveal.release());
  if (started == 1) return;
  reveals_.erase(pending);
  delete pending;
  SendRevealed(message.token, nullptr, 0);
}

void HostContext::OnPasswordRevealed(void* ctx, const char* password, size_t length) {
  const std::unique_ptr<PasswordReveal> reveal(static_cast<PasswordReveal*>(ctx));
  if (reveal == nullptr || reveal->host == nullptr) return;
  reveal->host->reveals_.erase(reveal.get());
  reveal->host->SendRevealed(reveal->token, password, length);
}

// Sent at once, never held behind an op's events: the answer refreshes no
// mirror. The shim zeroes its own buffer after done; the frame is a plain one
// (remote_shim_runtime.h, PostPasswordReveal).
void HostContext::SendRevealed(uint32_t token, const char* password, size_t length) {
  if (state_ == State::kEnded) return;
  TlvWriter answer;
  if (password != nullptr && length > 0) answer.Bytes(password, length);
  if (!send_(MessageOf(kOpReply, true, token, answer.Take()))) {
    fprintf(stderr, "cmux-chromium-host: a password reveal's answer was not sent\n");
  }
}

void HostContext::Watch(uint16_t op, const std::vector<control::Field>& key) {
  std::vector<std::vector<control::Field>>& keys = watched_[op];
  bool known = false;
  for (const std::vector<control::Field>& k : keys) known = known || k == key;
  if (!known && watched_count_ >= kMaxWatchedKeys) return Bad("too many watched mirror keys");
  if (!Produce(op, key)) return Bad("a malformed mirror key for op " + std::to_string(op));
  if (!known) {
    keys.push_back(key);
    ++watched_count_;
  }
}

bool HostContext::Produce(uint16_t op, const std::vector<control::Field>& key) {
  TlvReader r(key);
  return ProduceMirror(*this, op, r);
}

void HostContext::Refresh(const MirrorEvent& event) {
  mirrors_.EventArrived(event);
  ForEachMirrorRefreshedBy(event.kind, event.request, [&](uint16_t op) {
    if (mirrors_.Produce(*this, op, event)) return;
    auto found = watched_.find(op);
    if (found == watched_.end() || found->second.empty()) {
      // A mirror with no arguments needs no watch: produce it from its first refresh on.
      if (Produce(op, {})) {
        watched_[op].emplace_back();
        ++watched_count_;
      }
      return;
    }
    for (const std::vector<control::Field>& key : found->second) {
      if (key.empty() || HostMirrors::Names(op, event, key)) Produce(op, key);
    }
  });
  mirrors_.EventSent(event);
}

void HostContext::OnShimEvent(void* ctx, int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1,
                              const char* s2) {
  static_cast<HostContext*>(ctx)->ForwardEvent(kind, browser_id, request, a, b, s1, s2);
}

void HostContext::HelperExited(const HelperExit& ended) {
  ForwardEvent(kEventHelperExit, 0, ended.pid, ended.status, ended.identity.extension ? kHelperExitExtension : 0,
               ended.identity.type.c_str(), ended.identity.sub_type.c_str());
}

void HostContext::ForwardEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1,
                               const char* s2, const std::string* payload) {
  if (state_ == State::kEnded) return;
  if (dispatching_) {
    held_events_.push_back(HeldEvent{kind, browser_id, request, a, b, s1 ? s1 : "", s2 ? s2 : "",
                                     payload ? std::optional<std::string>(*payload) : std::nullopt});
    return;
  }
  // Chromium's counter reaching the minted range would make one id name two browsers.
  const int64_t new_browser = kind == CMUX_SHIM_AFTER_CREATED ? browser_id : kind == CMUX_SHIM_DEVTOOLS_OPENED ? a : 0;
  if (mint::IsMintedBrowser(new_browser)) return Bad("Chromium named a new browser by an id of the minted range");
  int32_t client = ClientOf(browser_id);
  // A relayed page's raw DevTools go on the provider link, off cmux's main thread.
  if (kind == CMUX_SHIM_DEVTOOLS_EVENT && agent_relays_ && s1 && agent_relays_->TakeDevToolsMessage(client, s1)) {
    return;
  }
  if (kind == CMUX_SHIM_BEFORE_CLOSE && agent_relays_) agent_relays_->BrowserClosed(client);
  int32_t out_request = request;
  int64_t out_a = a;
  int64_t out_b = b;
  if (kind == CMUX_SHIM_WINDOW_REQUEST_RESULT) {
    // a = the anchor whose window (request) gets the new tab; an INSERT's b carries the id minted for
    // that tab, which its AFTER_CREATED binds below (task 031).
    if (a > 0 && a <= INT32_MAX) out_a = ClientOf(static_cast<int>(a));
    out_b = window_request_tabs_.Result(request, browser_id, b);
  } else if (kind == CMUX_SHIM_AFTER_CREATED) {
    // b = opener << 32 | flags: the opener in cmux's id.
    const int opener = static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint64_t>(b) >> 32));
    if (opener > 0) {
      out_b = static_cast<int64_t>(static_cast<uint64_t>(static_cast<uint32_t>(ClientOf(opener))) << 32 |
                                   (static_cast<uint64_t>(b) & 0xffffffffu));
    }
  }
  MirrorEvent mirror_event{kind, request, client, a, b, std::nullopt};
  auto pending = request != 0 ? pending_binds_.find(BindKey(kind, request)) : pending_binds_.end();
  const bool created = pending != pending_binds_.end();
  if (created) {
    Bind(pending->second.minted, browser_id);
    if (pending->second.view) view_of_browser_[browser_id] = pending->second.view;
    if (auto geometry = geometry_awaiting_.find(pending->second.minted); geometry != geometry_awaiting_.end()) {
      const PageGeometry newest = geometry->second;
      geometry_awaiting_.erase(geometry);
      PlaceBrowser(browser_id, newest);
    }
    client = pending->second.minted;
    mirror_event.browser = client;
    mirror_event.profile = std::move(pending->second.profile);
    pending_binds_.erase(pending);
  } else if (kind == CMUX_SHIM_AFTER_CREATED && request == 0 && browser_id > 0 && !client_of_.count(browser_id)) {
    // A tab Chromium opened for a window request: the id its WINDOW_REQUEST_RESULT carried.
    const int opener = static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint64_t>(b) >> 32));
    if (const int32_t minted = window_request_tabs_.Take(static_cast<int>(a), opener)) {
      Bind(minted, browser_id);
      // The ring may have sent the minted id's geometry before this creation (PlaceFrame held it).
      if (auto geometry = geometry_awaiting_.find(minted); geometry != geometry_awaiting_.end()) {
        const PageGeometry newest = geometry->second;
        geometry_awaiting_.erase(geometry);
        PlaceBrowser(browser_id, newest);
      }
      client = minted;
      mirror_event.browser = client;
    }
  } else if (kind == CMUX_SHIM_DEVTOOLS_RESULT) {
    auto minted = devtools_ids_.find(DevToolsKey(browser_id, request));
    if (minted != devtools_ids_.end()) {
      out_request = minted->second;
      devtools_ids_.erase(minted);
    }
  }
  const int64_t window_before = mirrors_.WindowOf(client);
  Refresh(mirror_event);
  FollowPageWindows(client, window_before, kind == CMUX_SHIM_TAB_EVENT ? a : 0);
  TlvWriter event;
  if (payload) {
    choosers::EncodePayloadEvent(event, kind, client, out_request, out_a, out_b, *payload);
  } else {
    EncodeEvent(event, kind, client, out_request, out_a, out_b, s1, s2);
  }
  Post(MessageOf(kOpEvent, false, 0, event.Take()));
  if (created && replaying_held_events_) {
    created_during_replay_.push_back(client);  // Dispatch runs them after its op's ack
  } else if (created) {
    RunHeldForCreation(client);
  }
  if (kind == CMUX_SHIM_BEFORE_CLOSE) {
    Forget(client, browser_id);
    delegate_.BrowserClosed();
  }
}

int HostContext::Browser(int32_t client_id) {
  auto found = chromium_of_.find(client_id);
  return found == chromium_of_.end() ? client_id : found->second;
}

int32_t HostContext::ClientOf(int chromium_id) const {
  auto found = client_of_.find(chromium_id);
  return found == client_of_.end() ? chromium_id : found->second;
}

void HostContext::Bind(int32_t client_id, int chromium_id) {
  chromium_of_[client_id] = chromium_id;
  client_of_[chromium_id] = client_id;
  auto awaiting = text_input_awaiting_.find(client_id);
  if (awaiting == text_input_awaiting_.end()) return;
  const std::vector<uint32_t> tokens = std::move(awaiting->second);
  text_input_awaiting_.erase(awaiting);
  const int result = ArmTextInputWatch(chromium_id);
  for (uint32_t token : tokens) ReplyResult(token, result);
}

void HostContext::Forget(int32_t client_id, int chromium_id) {
  chromium_of_.erase(client_id);
  geometry_awaiting_.erase(client_id);
  page_visibility_.erase(client_id);
  // Its window's value stays with the tabs that remain (FollowPageWindows).
  page_windows_.BrowserClosed(client_id);
  UpdatePageActivity();
  client_of_.erase(chromium_id);
  text_input_.Forget(chromium_id);  // the fork ends the watch with the page
  wheel_acks_.Forget(chromium_id);
  for (auto& [op, keys] : watched_) {
    const size_t before = keys.size();
    std::erase_if(keys, [&](const std::vector<control::Field>& key) { return HostMirrors::NamesTab(op, key, client_id); });
    watched_count_ -= before - keys.size();
  }
  std::erase_if(devtools_ids_, [&](const auto& entry) {
    return static_cast<int>(static_cast<uint32_t>(entry.first >> 32)) == chromium_id;
  });
  // The shim forgets the closed browser's DevTools placement itself (ForgetDevTools).
  if (auto devtools = devtools_view_of_browser_.find(chromium_id); devtools != devtools_view_of_browser_.end()) {
    const uint64_t token = devtools->second;
    devtools_view_of_browser_.erase(devtools);
    ReleaseView(token);
  }
  auto view = view_of_browser_.find(chromium_id);
  if (view == view_of_browser_.end()) return;
  const uint64_t token = view->second;
  view_of_browser_.erase(view);
  ReleaseView(token);
}

void HostContext::PlaceDevTools(int chromium_id, uint64_t token) {
  uint64_t replaced = 0;
  if (auto held = devtools_view_of_browser_.find(chromium_id); held != devtools_view_of_browser_.end()) {
    replaced = held->second;
    devtools_view_of_browser_.erase(held);
  }
  if (token) devtools_view_of_browser_[chromium_id] = token;
  if (replaced && replaced != token) ReleaseView(replaced);
}

void HostContext::ReleaseView(uint64_t token) {
  for (const auto& [browser, other] : view_of_browser_) {
    if (other == token) return;  // a browser still has this parent view
  }
  for (const auto& [browser, other] : devtools_view_of_browser_) {
    if (other == token) return;  // a DevTools placement still names it
  }
  if (open_views_.erase(token)) {
    placed_.erase(token);
    views_.Close(token);  // its size stays (view_sizes_)
  }
}

void* HostContext::PageView(uint64_t token) {
  if (!token) return nullptr;
  if (!open_views_.count(token)) {
    if (open_views_.size() >= kMaxPageViews) {
      Bad("too many page views");
      return nullptr;
    }
    open_views_.insert(token);
    void* view = views_.Open(token);
    const auto size = view_sizes_.find(token);
    if (size != view_sizes_.end()) views_.Resize(token, size->second.width, size->second.height);
    if (dispatching_) dispatching_view_ = token;
    return view;
  }
  if (dispatching_) dispatching_view_ = token;
  return views_.Open(token);
}

void HostContext::Ack(uint32_t token) {
  if (!token) return;
  control::Message ack = MessageOf(kOpAck, true, token, {});
  if (dispatching_) {
    held_replies_.push_back(std::move(ack));
  } else {
    Post(std::move(ack));
  }
}

void HostContext::Reply(uint32_t token, const TlvWriter& reply) {
  if (!token) return;
  control::Message message = MessageOf(kOpReply, true, token, reply.fields());
  if (dispatching_) {
    held_replies_.push_back(std::move(message));
  } else {
    Post(std::move(message));
  }
}

void HostContext::BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser) {
  switch (op) {
    case kOpTabAdd:
    case kOpTabDuplicate:
      if (result > 0) Bind(minted, static_cast<int>(result));
      break;
    case kOpDevtoolsCall:
      if (result > 0) {
        devtools_ids_[DevToolsKey(Browser(client_browser), static_cast<int32_t>(result))] = minted;
      } else {
        // The header's 0 for a refused call is a DEVTOOLS_RESULT with a = 0 in host mode.
        TlvWriter refused;
        EncodeEvent(refused, CMUX_SHIM_DEVTOOLS_RESULT, client_browser, minted, 0, 0, "", "");
        held_replies_.push_back(MessageOf(kOpEvent, false, 0, refused.Take()));
      }
      break;
    default:
      break;
  }
}

void HostContext::BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int request, int64_t result) {
  if (result != 1) {
    // The call refused: no event will name the browser.
    fprintf(stderr, "cmux-chromium-host: op %u refused minted id %d\n", op, minted);
    geometry_awaiting_.erase(minted);
    return;
  }
  if (pending_binds_.size() >= kMaxPendingBinds) return Bad("too many browsers waiting for their creation");
  pending_binds_[BindKey(event_kind, request)] = PendingBind{minted, dispatching_view_, dispatching_profile_};
}

void HostContext::PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value) {
  std::string key_bytes;
  std::string value_bytes;
  if (!key.Encode(&key_bytes)) return Bad("a mirror key over a field bound");
  if (value.Encode(&value_bytes)) {
    TlvWriter mirror;
    mirror.I32(op);
    mirror.Bytes(key_bytes.data(), key_bytes.size());
    mirror.Bytes(value_bytes.data(), value_bytes.size());
    if (BodySize(mirror.fields()) <= control::kMaxBody) {
      Post(MessageOf(kOpMirror, false, 0, mirror.Take()));
      return;
    }
  }
  fprintf(stderr, "cmux-chromium-host: mirror %u is over the frame bound: forgotten\n", op);
  ForgetMirror(op, key);
}

void HostContext::ForgetMirror(uint16_t op, const TlvWriter& key) {
  std::string key_bytes;
  if (!key.Encode(&key_bytes)) return Bad("a mirror key over a field bound");
  TlvWriter forget;
  forget.I32(op);
  forget.Bytes(key_bytes.data(), key_bytes.size());
  Post(MessageOf(kOpMirror, false, 0, forget.Take()));
}

void HostContext::RefreshMirror(uint16_t op, const TlvWriter& key, uint32_t wildcards) {
  if (mirrors_.Refresh(*this, op, key.fields(), wildcards)) return;
  // A watched mirror: only the keys cmux watches, so no key it never asked for gets a value
  // that nothing refreshes later.
  auto found = watched_.find(op);
  if (found == watched_.end()) return;
  for (const std::vector<control::Field>& watched : found->second) {
    if (HostMirrors::KeyMatches(watched, key.fields(), wildcards)) Produce(op, watched);
  }
}

bool HostContext::Post(control::Message message) {
  if (send_(message)) return true;
  // Over a frame bound (a value past 64 KiB goes as shm, task 020) or the channel ended.
  fprintf(stderr, "cmux-chromium-host: op %#x not sent\n", message.op);
  return false;
}

void HostContext::Bad(const std::string& what) {
  if (state_ == State::kEnded) return;
  state_ = State::kEnded;
  waiting_.clear();
  delegate_.BadMessage(what);
}

// Chromium never opens a window of its own in the host (it would be a
// visible host window), and no one is asked inside its navigation: with no
// window request handler the shim decides each request with the policy cmux
// pushed (cmux_shim_set_window_request_policy) and reports it as
// CMUX_SHIM_WINDOW_REQUEST_RESULT, with the id the host mints for an
// INSERT's tab (task 031). No focus handler: the shim grants a focus request
// only for a page cmux marked embedder-active
// (CEFShim/src/embedder_focus_policy.h), so the focused pane's page keeps
// Chromium's focus after its own loads and a background pane's load takes none.
void HostContext::InstallHostPolicies() {
  cmux_shim_set_focus_request_handler(nullptr);
  cmux_shim_set_window_request_handler(nullptr);
}

// The host's own policies stay in place whatever cmux installs: the shim's
// embedder-active rule decides focus and cmux's pushed policy windows (above).
// cmux routes keys first in its own process: with no unhandled-key handler,
// a chord the page leaves unhandled goes back as KEY_UNHANDLED with its
// frame's input seq (SendHostKeyEvent and OnKeyEvent in shim_client.mm,
// task 030); DevTools keys follow in task 033.
void InstallPolicySetFocusRequestHandler(HostContext& ctx, bool) {
  ctx.InstallHostPolicies();
}
void InstallPolicySetWindowRequestHandler(HostContext& ctx, bool) {
  ctx.InstallHostPolicies();
}
void InstallPolicySetUnhandledKeyHandler(HostContext&, bool) {
  cmux_shim_set_unhandled_key_handler(nullptr);
}
void InstallPolicyDevtoolsSetKeyHandler(HostContext&, bool) {
  cmux_shim_devtools_set_key_handler(nullptr);
}

}  // namespace cmux_host
