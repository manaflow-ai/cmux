// The Chromium Host's dispatcher (host_dispatch.h): one generated case per
// shim export (generated/host_dispatch.inc), the id maps, the watched mirror
// keys and the host's focus and window-request policies. No AppKit: the page
// views are behind PageViews (host_page_views.mm).

#include <dlfcn.h>
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

HostContext::HostContext(Send send, HostDelegate& delegate, PageViews& views, Resolve resolve)
    : send_(std::move(send)), delegate_(delegate), views_(views), resolve_(std::move(resolve)) {}

void* HostContext::DefaultResolve(const char* name) {
  return dlsym(RTLD_DEFAULT, name);
}

void HostContext::Attach() {
  std::vector<const char*> found;
  for (const auto& entry : kOptionalExports) {
    if (entry.op == 0) continue;  // the table's placeholder when the header declares every export
    void* symbol = resolve_ ? resolve_(entry.name) : nullptr;
    if (symbol == nullptr) continue;
    optional_exports_[entry.op] = symbol;
    found.push_back(entry.name);
  }
  ProduceAttach(true);
  TlvWriter hello;
  hello.Str(kWireID);
  hello.StrList(found.data(), static_cast<int>(found.size()));
  Post(MessageOf(control::kOpHello, false, 0, hello.Take()));
}

void* HostContext::OptionalExport(uint16_t op) const {
  auto found = optional_exports_.find(op);
  return found == optional_exports_.end() ? nullptr : found->second;
}

bool HostContext::HandleHello(const control::Message& message) {
  TlvReader r(message.fields);
  const std::optional<std::string> wire = r.Str();
  const std::optional<std::string> abi = r.Str();
  if (!r.ok() || !r.AtEnd()) return false;
  return wire == std::optional<std::string>(kWireID) && abi == std::optional<std::string>(kShimAbiID);
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
  if (state_ == State::kEnded) return;
  if (!hello_) {
    if (message.op != control::kOpHello) return Bad("an op before the hello");
    if (!HandleHello(message)) return Bad("a hello of another op table or shim header");
    hello_ = true;
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
      if (IsMirrorOp(message.op)) return Watch(message.op, message.fields);
      Dispatch(message);
      return;
  }
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

void HostContext::Dispatch(const control::Message& message) {
  if (message.op == kOpShutdown) {
    // CefShutdown runs once the loop has ended (browser_host_main.mm), never inside a task.
    Ack(message.token);
    delegate_.Quit();
    return;
  }
  if (message.op == kOpCreateWindow || message.op == kOpDevtoolsCall) {
    // Header order: the minted id, then create_window's request and parent
    // view, or devtools_call's browser.
    TlvReader peek(message.fields);
    const int32_t minted = peek.I32();
    const int32_t second = peek.I32();
    if (message.op == kOpCreateWindow) {
      const uint64_t view = peek.View();
      peek.I32();  // width
      peek.I32();  // height
      peek.Str();  // url
      const std::string profile = peek.Str().value_or(std::string());
      if (peek.ok()) pending_creates_[second] = PendingCreate{minted, view, profile};
    } else {
      devtools_call_browser_ = second;
    }
  }
  dispatching_ = true;
  dispatching_op_ = message.op;
  TlvReader r(message.fields);
  const bool ok = DispatchOp(*this, message.op, message.token, r);
  dispatching_ = false;
  dispatching_op_ = 0;
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
  if (kind == CMUX_SHIM_AFTER_CREATED && request != 0) {
    auto pending = pending_creates_.find(request);
    if (pending != pending_creates_.end()) {
      Bind(pending->second.minted, browser_id);
      if (pending->second.view) view_of_browser_[browser_id] = pending->second.view;
      client = pending->second.minted;
      mirror_event.browser = client;
      mirror_event.profile = std::move(pending->second.profile);
      pending_creates_.erase(pending);
    }
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
}

void HostContext::Forget(int32_t client_id, int chromium_id) {
  chromium_of_.erase(client_id);
  client_of_.erase(chromium_id);
  for (auto& entry : watched_) {
    const uint16_t op = entry.first;
    std::vector<std::vector<control::Field>>& keys = entry.second;
    const size_t before = keys.size();
    std::erase_if(keys, [&](const std::vector<control::Field>& key) { return HostMirrors::NamesTab(op, key, client_id); });
    watched_count_ -= before - keys.size();
  }
  std::erase_if(devtools_ids_, [&](const auto& entry) {
    return static_cast<int>(static_cast<uint32_t>(entry.first >> 32)) == chromium_id;
  });
  auto view = view_of_browser_.find(chromium_id);
  if (view == view_of_browser_.end()) return;
  const uint64_t token = view->second;
  view_of_browser_.erase(view);
  for (const auto& [browser, other] : view_of_browser_) {
    if (other == token) return;  // another browser still has this parent view
  }
  open_views_.erase(token);
  views_.Close(token);
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

void HostContext::BindMinted(uint16_t op, int32_t minted, int64_t result) {
  switch (op) {
    case kOpTabAdd:
    case kOpTabDuplicate:
      if (result > 0) Bind(minted, static_cast<int>(result));
      break;
    case kOpDevtoolsCall:
      if (result > 0) {
        devtools_ids_[DevToolsKey(Browser(devtools_call_browser_), static_cast<int32_t>(result))] = minted;
      } else {
        // The header's 0 for a refused call is a DEVTOOLS_RESULT with a = 0 in host mode.
        TlvWriter refused;
        EncodeEvent(refused, CMUX_SHIM_DEVTOOLS_RESULT, devtools_call_browser_, minted, 0, 0, "", "");
        held_replies_.push_back(MessageOf(kOpEvent, false, 0, refused.Take()));
      }
      break;
    default:
      break;
  }
}

void HostContext::BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int32_t request, int64_t started) {
  // ForwardEvent binds the id at the event (create_window: AFTER_CREATED with
  // its request); a call that did not start sends no such event.
  if (started == 1) return;
  if (op == kOpCreateWindow && event_kind == CMUX_SHIM_AFTER_CREATED) pending_creates_.erase(request);
  fprintf(stderr, "cmux-chromium-host: op %u (minted %d) refused\n", static_cast<unsigned>(op), minted);
}

// No value (forget) when `value` has no fields: BEFORE_CLOSE's keys, as the
// remote shim reads a MIRROR with no value bytes.
void HostContext::PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value) {
  std::string key_bytes;
  std::string value_bytes;
  if (!key.Encode(&key_bytes) || !value.Encode(&value_bytes)) {
    // A field over 64 KiB: shm payloads are task 020.
    fprintf(stderr, "cmux-chromium-host: mirror %u not sent (a field over the bound)\n", static_cast<unsigned>(op));
    return;
  }
  TlvWriter mirror;
  mirror.I32(op);
  mirror.Bytes(key_bytes.data(), key_bytes.size());
  if (!value.fields().empty()) mirror.Bytes(value_bytes.data(), value_bytes.size());
  Post(MessageOf(kOpMirror, false, 0, mirror.Take()));
}

void HostContext::Post(control::Message message) {
  if (send_(message)) return;
  // Over a frame bound (a value past 64 KiB goes as shm, task 020) or the channel ended.
  fprintf(stderr, "cmux-chromium-host: op %#x not sent\n", message.op);
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
