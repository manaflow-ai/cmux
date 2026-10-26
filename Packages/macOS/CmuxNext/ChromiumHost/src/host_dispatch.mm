// The Chromium Host's dispatcher (host_dispatch.h): one generated case per
// shim export (generated/host_dispatch.inc), the id maps, the watched mirror
// keys and the host's focus and window-request policies. No AppKit: the page
// views are behind PageViews (host_page_views.mm).

#include <unistd.h>

#include <cstdio>
#include <utility>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"

namespace cmux_host {

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
// create_window and create_placeholder_window calls whose AFTER_CREATED has
// not come yet.
constexpr size_t kMaxPendingBinds = 4096;

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

void HostContext::Attach() {
  ProduceAttach(true);
  std::vector<const char*> exports;
  for (const auto& entry : kOptionalExports) {
    if (OptionalExport(entry.op)) exports.push_back(entry.name);
  }
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
  Ack(initialize_token_);
  ProduceAttach(false);
  while (!waiting_.empty() && state_ == State::kRunning) {
    control::Message message = std::move(waiting_.front());
    waiting_.pop_front();
    Handle(message);
  }
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
  switch (state_) {
    case State::kEnded:
      return;
    case State::kInitializing:
      waiting_.push_back(std::move(message));
      return;
    case State::kPreinit:
      if (message.op == kOpInitialize) {
        if (!HandleInitialize(message)) Bad("a malformed initialize");
      } else if (IsMirrorOp(message.op)) {
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
      if (IsMirrorOp(message.op)) return Watch(message.op, message.fields);
      Dispatch(message);
      return;
  }
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

void HostContext::Dispatch(const control::Message& message) {
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
  dispatching_op_ = message.op;
  dispatching_view_ = 0;
  dispatching_profile_ = std::move(profile);
  TlvReader r(message.fields);
  const bool ok = DispatchOp(*this, message.op, message.token, r);
  dispatching_ = false;
  dispatching_op_ = 0;
  dispatching_view_ = 0;
  dispatching_profile_.reset();
  if (ok && placed_browser) PlaceDevTools(Browser(placed_browser), placed_view);
  std::vector<HeldEvent> events;
  events.swap(held_events_);
  for (const HeldEvent& e : events) ForwardEvent(e.kind, e.browser_id, e.request, e.a, e.b, e.s1.c_str(), e.s2.c_str());
  std::vector<control::Message> replies;
  replies.swap(held_replies_);
  for (control::Message& reply : replies) Post(std::move(reply));
  if (!ok) Bad("a malformed op " + std::to_string(message.op));
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

void HostContext::ForwardEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1,
                               const char* s2) {
  if (state_ == State::kEnded) return;
  if (dispatching_) {
    held_events_.push_back(HeldEvent{kind, browser_id, request, a, b, s1 ? s1 : "", s2 ? s2 : ""});
    return;
  }
  int32_t client = ClientOf(browser_id);
  int32_t out_request = request;
  MirrorEvent mirror_event{kind, request, client, a, b, std::nullopt};
  auto pending = request != 0 ? pending_binds_.find(BindKey(kind, request)) : pending_binds_.end();
  if (pending != pending_binds_.end()) {
    Bind(pending->second.minted, browser_id);
    if (pending->second.view) view_of_browser_[browser_id] = pending->second.view;
    client = pending->second.minted;
    mirror_event.browser = client;
    mirror_event.profile = std::move(pending->second.profile);
    pending_binds_.erase(pending);
  } else if (kind == CMUX_SHIM_DEVTOOLS_RESULT) {
    auto minted = devtools_ids_.find(DevToolsKey(browser_id, request));
    if (minted != devtools_ids_.end()) {
      out_request = minted->second;
      devtools_ids_.erase(minted);
    }
  }
  Refresh(mirror_event);
  TlvWriter event;
  EncodeEvent(event, kind, client, out_request, a, b, s1, s2);
  Post(MessageOf(kOpEvent, false, 0, event.Take()));
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
  client_of_.erase(chromium_id);
  text_input_.Forget(chromium_id);  // the fork ends the watch with the page
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
  if (open_views_.erase(token)) views_.Close(token);
}

void* HostContext::PageView(uint64_t token) {
  if (!token) return nullptr;
  if (!open_views_.count(token)) {
    if (open_views_.size() >= kMaxPageViews) {
      Bad("too many page views");
      return nullptr;
    }
    open_views_.insert(token);
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

// Chromium never focuses a page on its own: as in process (CEFTab+Focus.swift),
// a request is granted only inside cmux's cmux_shim_set_focus.
int HostContext::OnFocusRequest(void* ctx, int, int) {
  return static_cast<HostContext*>(ctx)->dispatching_op_ == kOpSetFocus ? 1 : 0;
}

// Chromium never opens a window of its own in the host (it would be a
// visible host window): a tab, window or popup request becomes a tab in the
// window of the tab that asked, which cmux adopts from AFTER_CREATED, until
// cmux pushes its WindowRequestPolicy (task 031). Incognito and app windows
// open nothing.
int HostContext::OnWindowRequest(void*, int kind, int, int source_browser_id, int, int, int, int, int, int,
                                 const char*, const char*) {
  return kind <= 2 ? source_browser_id : 0;
}

void HostContext::InstallHostPolicies() {
  cmux_shim_set_focus_request_handler(&HostContext::OnFocusRequest);
  cmux_shim_set_window_request_handler(&HostContext::OnWindowRequest);
}

// The host's own handlers stay in place whatever cmux installs: the host
// decides focus and windows itself (above); keys go on to Chromium until
// cmux routes them first (tasks 030 and 033).
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
