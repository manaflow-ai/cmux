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

bool KeyNames(const std::vector<control::Field>& key, int32_t client_id) {
  return !key.empty() && key[0].type == control::Type::kI32 && key[0].integer == client_id;
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

HostContext::HostContext(Send send, HostDelegate& delegate, PageViews& views)
    : send_(std::move(send)), delegate_(delegate), views_(views) {}

void HostContext::Attach(int fork_api, int pid) {
  ProduceAttach(true);
  TlvWriter hello;
  EncodeEvent(hello, kEventAttach, 0, 0, fork_api, pid, cmux_shim_abi_id(), "");
  Post(MessageOf(kOpEvent, false, 0, hello.Take()));
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
      if (peek.ok()) pending_creates_[second] = PendingCreate{minted, view};
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
      if (key.empty() || KeyNames(key, event.browser)) Produce(op, key);
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
  if (kind == CMUX_SHIM_AFTER_CREATED && request != 0) {
    auto pending = pending_creates_.find(request);
    if (pending != pending_creates_.end()) {
      Bind(pending->second.minted, browser_id);
      if (pending->second.view) view_of_browser_[browser_id] = pending->second.view;
      client = pending->second.minted;
      pending_creates_.erase(pending);
    }
  } else if (kind == CMUX_SHIM_DEVTOOLS_RESULT) {
    auto minted = devtools_ids_.find(DevToolsKey(browser_id, request));
    if (minted != devtools_ids_.end()) {
      out_request = minted->second;
      devtools_ids_.erase(minted);
    }
  }
  Refresh(MirrorEvent{kind, request, client, a, b});
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
  for (auto& [op, keys] : watched_) {
    const size_t before = keys.size();
    std::erase_if(keys, [&](const std::vector<control::Field>& key) { return KeyNames(key, client_id); });
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
    case kOpCreateWindow:
      // Bound at AFTER_CREATED(request); a refused creation sends none.
      if (result != 1) {
        std::erase_if(pending_creates_, [&](const auto& entry) { return entry.second.minted == minted; });
        fprintf(stderr, "cmux-chromium-host: create_window %d refused\n", minted);
      }
      break;
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

void HostContext::PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value) {
  TlvWriter mirror;
  mirror.I32(op);
  mirror.I32(static_cast<int32_t>(key.fields().size()));
  mirror.Append(key);
  mirror.Append(value);
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
