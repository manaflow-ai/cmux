// The navigation, window and count mirrors' producers (host_mirror.h). No
// AppKit: the values come from the shim and the event.

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_mirror.h"

#include "generated/host_dispatch.inc"

namespace cmux_host {
namespace {

// cmux_tab_event_t of the fork (include/cef_cmux.h; CEFForkTabEvent in
// CEFShimEvent.swift): CMUX_SHIM_TAB_EVENT's request.
constexpr int kTabInserted = 0;
constexpr int kTabMoved = 2;
constexpr int kTabWindowDestroyed = 6;

// Whose key a mirror is: the host's (no arguments) or one tab's ([browser_id]).
enum class Scope { kHost, kTab };

struct Producer {
  uint16_t op;
  Scope scope;
};

constexpr Producer kProducers[] = {
    {kOpTabNavigationEntries, Scope::kTab},
    {kOpTabNavigationState, Scope::kTab},
    {kOpTabWindowId, Scope::kTab},
    {kOpWindowCount, Scope::kHost},
    {kOpLiveBrowserCount, Scope::kHost},
    {kOpForeignBrowserCount, Scope::kHost},
};

const Producer* ProducerOf(uint16_t op) {
  for (const Producer& producer : kProducers) {
    if (producer.op == op) return &producer;
  }
  return nullptr;
}

// The value the event itself reports for `op`, when it has one.
bool EventValue(uint16_t op, const MirrorEvent& event, int64_t* value) {
  const bool tab_event = event.kind == CMUX_SHIM_TAB_EVENT;
  if (op == kOpTabWindowId &&
      (event.kind == CMUX_SHIM_AFTER_CREATED ||
       (tab_event && (event.request == kTabInserted || event.request == kTabMoved)))) {
    *value = event.a;  // the tab's window
    return true;
  }
  if (op == kOpWindowCount && tab_event && event.request == kTabWindowDestroyed) {
    *value = event.b;  // the windows that remain
    return true;
  }
  return false;
}

}  // namespace

void HostMirrors::EventArrived(const MirrorEvent& event) {
  if (event.kind == CMUX_SHIM_AFTER_CREATED && event.browser != 0) open_tabs_.insert(event.browser);
}

void HostMirrors::EventSent(const MirrorEvent& event) {
  if (event.kind == CMUX_SHIM_BEFORE_CLOSE) open_tabs_.erase(event.browser);
}

bool HostMirrors::Produce(HostContext& ctx, uint16_t op, const MirrorEvent& event) const {
  const Producer* producer = ProducerOf(op);
  if (producer == nullptr) return false;
  TlvWriter key;
  if (producer->scope == Scope::kTab) {
    // A window-level event, or a browser cmux has no tab for (DevTools).
    if (!open_tabs_.count(event.browser)) return true;
    key.I32(event.browser);
    if (event.kind == CMUX_SHIM_BEFORE_CLOSE) {
      ctx.ForgetMirror(op, key);
      return true;
    }
  }
  int64_t reported = 0;
  if (EventValue(op, event, &reported)) {
    TlvWriter value;
    value.I32(static_cast<int32_t>(reported));
    ctx.PushMirror(op, key, value);
    return true;
  }
  TlvReader r(key.Take());
  ProduceMirror(ctx, op, r);
  return true;
}

}  // namespace cmux_host
