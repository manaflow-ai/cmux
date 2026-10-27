// ClientIds (host_client_ids.h). No CEF, no AppKit: the event kinds come from
// the shim header, the ranges from chromium_host_mint.h.

#include "host_client_ids.h"

#include "cmux_cef_shim.h"

namespace cmux_host {
namespace {

bool IsChromiumID(int64_t id) {
  return id > 0 && id <= INT32_MAX;
}

}  // namespace

int ClientIds::Browser(int32_t client_id) const {
  if (!mint::IsMintedBrowser(client_id)) return client_id;
  auto found = chromium_of_.find(client_id);
  return found == chromium_of_.end() ? 0 : found->second;
}

int32_t ClientIds::ClientOf(int chromium_id) const {
  auto found = client_of_.find(chromium_id);
  return found == client_of_.end() ? chromium_id : found->second;
}

void ClientIds::BeginCall() {
  in_call_ = true;
}

void ClientIds::EndCall() {
  in_call_ = false;
  std::vector<Held> held;
  held.swap(held_);
  for (Held& entry : held) emit_(entry.in_client_ids ? entry.event : ToClient(entry.event));
}

ClientIds::Outcome ClientIds::Bind(int32_t minted, int64_t result) {
  if (!mint::IsMintedBrowser(minted)) return Outcome::kBad;
  if (!IsChromiumID(result)) {
    Send(Event{mint::kEventCreateFailed, minted, 0, 0, 0, {}, {}});
    return Outcome::kRefused;
  }
  return Link(minted, result);
}

ClientIds::Outcome ClientIds::BindOnEvent(int32_t minted, int event_kind, int32_t request, int64_t started) {
  if (!mint::IsMintedBrowser(minted) || request == 0) return Outcome::kBad;
  if (started != 1) {
    Send(Event{mint::kEventCreateFailed, minted, request, 0, 0, {}, {}});
    return Outcome::kRefused;
  }
  const PendingKey key{event_kind, request};
  if (pending_.size() >= kMaxPendingCreates || pending_.count(key) || awaiting_.count(minted) ||
      chromium_of_.count(minted)) {
    return Outcome::kBad;
  }
  pending_.emplace(key, minted);
  awaiting_.insert(minted);
  return Outcome::kBound;
}

ClientIds::Outcome ClientIds::BindDevToolsCall(int32_t client_browser, int32_t minted, int64_t result) {
  if (!mint::IsMintedDevTools(minted)) return Outcome::kBad;
  if (!IsChromiumID(result)) {
    Send(Event{CMUX_SHIM_DEVTOOLS_RESULT, client_browser, minted, 0, 0, {}, {}});
    return Outcome::kRefused;
  }
  if (devtools_.size() >= kMaxDevToolsCalls) return Outcome::kBad;
  const bool inserted = devtools_.emplace(DevToolsKey(Browser(client_browser), result), minted).second;
  return inserted ? Outcome::kBound : Outcome::kBad;
}

bool ClientIds::FromShim(const Event& chromium) {
  const bool new_browser = chromium.kind == CMUX_SHIM_AFTER_CREATED || chromium.kind == CMUX_SHIM_DEVTOOLS_OPENED;
  const int64_t created = chromium.kind == CMUX_SHIM_DEVTOOLS_OPENED ? chromium.a : chromium.browser_id;
  if (new_browser && mint::IsMintedBrowser(created)) return false;
  if (in_call_) {
    held_.push_back(Held{chromium, false});
  } else {
    emit_(ToClient(chromium));
  }
  return true;
}

ClientIds::Event ClientIds::ToClient(const Event& chromium) {
  if (!pending_.empty() && chromium.request != 0 && IsChromiumID(chromium.browser_id)) {
    auto pending = pending_.find(PendingKey{chromium.kind, chromium.request});
    if (pending != pending_.end()) {
      const int32_t minted = pending->second;
      pending_.erase(pending);
      awaiting_.erase(minted);
      Link(minted, chromium.browser_id);
    }
  }
  Event out = chromium;
  out.browser_id = ClientOf(chromium.browser_id);
  switch (chromium.kind) {
    case CMUX_SHIM_AFTER_CREATED: {
      const uint64_t packed = static_cast<uint64_t>(chromium.b);
      const int opener = static_cast<int32_t>(static_cast<uint32_t>(packed >> 32));
      if (opener != 0) {
        const uint64_t client = static_cast<uint32_t>(ClientOf(opener));
        out.b = static_cast<int64_t>((client << 32) | (packed & 0xffffffffu));
      }
      break;
    }
    case CMUX_SHIM_DEVTOOLS_OPENED:
    case CMUX_SHIM_DEVTOOLS_CLOSED:
      if (IsChromiumID(chromium.a)) out.a = ClientOf(static_cast<int>(chromium.a));
      break;
    case CMUX_SHIM_DEVTOOLS_RESULT: {
      auto minted = devtools_.find(DevToolsKey(chromium.browser_id, chromium.request));
      if (minted != devtools_.end()) {
        out.request = minted->second;
        devtools_.erase(minted);
      }
      break;
    }
    case CMUX_SHIM_BEFORE_CLOSE:
      Forget(chromium.browser_id);
      break;
    default:
      break;
  }
  return out;
}

void ClientIds::Send(Event event) {
  if (in_call_) {
    held_.push_back(Held{std::move(event), true});
  } else {
    emit_(event);
  }
}

uint64_t ClientIds::DevToolsKey(int chromium_browser, int64_t message_id) {
  return (static_cast<uint64_t>(static_cast<uint32_t>(chromium_browser)) << 32) |
         static_cast<uint32_t>(message_id);
}

ClientIds::Outcome ClientIds::Link(int32_t minted, int64_t chromium) {
  if (chromium_of_.count(minted) || client_of_.count(static_cast<int>(chromium))) return Outcome::kBad;
  if (chromium_of_.size() >= kMaxBrowsers) return Outcome::kBad;
  chromium_of_.emplace(minted, static_cast<int>(chromium));
  client_of_.emplace(static_cast<int>(chromium), minted);
  return Outcome::kBound;
}

void ClientIds::Forget(int chromium_id) {
  auto client = client_of_.find(chromium_id);
  if (client != client_of_.end()) {
    chromium_of_.erase(client->second);
    client_of_.erase(client);
  }
  const uint32_t browser = static_cast<uint32_t>(chromium_id);
  std::erase_if(devtools_, [browser](const auto& entry) { return static_cast<uint32_t>(entry.first >> 32) == browser; });
}

}  // namespace cmux_host
