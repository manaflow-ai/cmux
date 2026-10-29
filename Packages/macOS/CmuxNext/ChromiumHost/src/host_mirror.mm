// The tab and host mirrors' producers (host_mirror.h). No AppKit: the values
// come from the shim and the event.

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_mirror.h"

#include <algorithm>

#include "generated/host_dispatch.inc"

namespace cmux_host {
namespace {

// cmux_tab_event_t of the fork (include/cef_cmux.h; CEFForkTabEvent in
// CEFShimEvent.swift): CMUX_SHIM_TAB_EVENT's request.
constexpr int kTabInserted = 0;
constexpr int kTabMoved = 2;
constexpr int kTabRemoved = 3;
constexpr int kTabExtensionActionsChanged = 4;
constexpr int kTabWindowDestroyed = 6;
constexpr int kTabExtensionsChanged = 7;
constexpr int kTabSidePanelChanged = 12;

// Whose key a mirror is: the host's (no arguments), one tab's ([browser_id]),
// or one tab's at cmux's fixed icon size ([browser_id, icon_px]).
enum class Key { kHost, kTab, kTabIcon };

struct Producer {
  uint16_t op;
  Key key;
};

constexpr Producer kProducers[] = {
    {kOpTabNavigationEntries, Key::kTab},
    {kOpTabNavigationState, Key::kTab},
    {kOpTabWindowId, Key::kTab},
    {kOpWindowCount, Key::kHost},
    {kOpLiveBrowserCount, Key::kHost},
    {kOpForeignBrowserCount, Key::kHost},
    {kOpSidePanelState, Key::kTab},
    {kOpExtActions, Key::kTabIcon},
    {kOpExtList, Key::kTab},
    {kOpExtCommands, Key::kTab},
    {kOpOmniboxKeywords, Key::kTab},
    {kOpRendererClientIds, Key::kTab},
};

// Which tabs a refresh names. Every (mirror, event) not listed names the
// event's tab.
enum class Scope { kTab, kWindow, kProfile };

struct ScopeRow {
  uint16_t op;
  int tab_event;  // the CMUX_SHIM_TAB_EVENT sub-kind
  Scope scope;
};

// The scope belongs to the (mirror, event) pair: a new mirror that lists
// TAB_EVENT 4, 7 or 12 refreshes the event's tab until it has a row here.
constexpr ScopeRow kScopes[] = {
    // A window's toolbar actions or side panel changed (an install or enable
    // reports 4 too); the event's tab is the window's active one.
    {kOpExtActions, kTabExtensionActionsChanged, Scope::kWindow},
    {kOpSidePanelState, kTabSidePanelChanged, Scope::kWindow},
    // An extension was installed, removed, enabled or disabled in the profile.
    {kOpExtList, kTabExtensionsChanged, Scope::kProfile},
    {kOpExtCommands, kTabExtensionsChanged, Scope::kProfile},
    {kOpOmniboxKeywords, kTabExtensionsChanged, Scope::kProfile},
};

const Producer* ProducerOf(uint16_t op) {
  for (const Producer& producer : kProducers) {
    if (producer.op == op) return &producer;
  }
  return nullptr;
}

Scope ScopeOf(uint16_t op, const MirrorEvent& event) {
  if (event.kind != CMUX_SHIM_TAB_EVENT) return Scope::kTab;
  for (const ScopeRow& row : kScopes) {
    if (row.op == op && row.tab_event == event.request) return row.scope;
  }
  return Scope::kTab;
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

bool FirstFieldIs(const std::vector<control::Field>& key, int64_t id) {
  return !key.empty() && key[0].type == control::Type::kI32 && key[0].integer == id;
}

void Add(std::vector<int32_t>& tabs, const std::set<int32_t>& more) {
  tabs.insert(tabs.end(), more.begin(), more.end());
}

}  // namespace

bool HostMirrors::Names(uint16_t op, const MirrorEvent& event, const std::vector<control::Field>& key) {
  if (op == kOpPopupWindowBounds) return event.kind == CMUX_SHIM_TAB_EVENT && FirstFieldIs(key, event.a);
  return FirstFieldIs(key, event.browser);
}

bool HostMirrors::NamesTab(uint16_t op, const std::vector<control::Field>& key, int32_t browser) {
  return op != kOpPopupWindowBounds && FirstFieldIs(key, browser);
}

void HostMirrors::EventArrived(const MirrorEvent& event) {
  if (event.kind == CMUX_SHIM_AFTER_CREATED && event.browser != 0) {
    tabs_.try_emplace(event.browser);
    Place(event.browser, event.a);  // a = 0: a popup Chromium has not placed yet
    if (event.profile) SetProfile(event.browser, *event.profile);
    return;
  }
  if (event.kind == CMUX_SHIM_TAB_EVENT && (event.request == kTabInserted || event.request == kTabMoved) &&
      tabs_.count(event.browser)) {
    Place(event.browser, event.a);
  }
}

void HostMirrors::EventSent(const MirrorEvent& event) {
  if (event.kind == CMUX_SHIM_BEFORE_CLOSE) return Close(event.browser);
  if (event.kind != CMUX_SHIM_TAB_EVENT) return;
  if (event.request == kTabRemoved && event.a != 0 && WindowOf(event.browser) == event.a) {
    Unplace(event.browser);  // a later inserted names its next window
  } else if (event.request == kTabWindowDestroyed && event.a != 0) {
    WindowDestroyed(event.a);
  }
}

int64_t HostMirrors::WindowOf(int32_t browser) const {
  auto found = tabs_.find(browser);
  return found == tabs_.end() ? 0 : found->second.window;
}

std::optional<std::string> HostMirrors::ProfileOf(int32_t browser) const {
  auto found = tabs_.find(browser);
  return found == tabs_.end() ? std::nullopt : found->second.profile;
}

void HostMirrors::Place(int32_t browser, int64_t window) {
  Tab& tab = tabs_[browser];
  if (window == 0 || tab.window == window) return;
  Unplace(browser);
  tab.window = window;
  tabs_of_window_[window].insert(browser);
  // A window has one profile: the tab and its window tell each other theirs.
  if (tab.profile) {
    profile_of_window_.try_emplace(window, *tab.profile);
  } else if (auto known = profile_of_window_.find(window); known != profile_of_window_.end()) {
    SetProfile(browser, known->second);
  }
}

void HostMirrors::SetProfile(int32_t browser, const std::string& profile) {
  Tab& tab = tabs_[browser];
  if (tab.profile == profile) return;
  if (tab.profile) {
    auto old = tabs_of_profile_.find(*tab.profile);
    if (old != tabs_of_profile_.end() && old->second.erase(browser) && old->second.empty()) tabs_of_profile_.erase(old);
  }
  tab.profile = profile;
  tabs_of_profile_[profile].insert(browser);
  if (tab.window != 0) profile_of_window_.try_emplace(tab.window, profile);
}

void HostMirrors::Unplace(int32_t browser) {
  auto found = tabs_.find(browser);
  if (found == tabs_.end() || found->second.window == 0) return;
  auto window = tabs_of_window_.find(found->second.window);
  if (window != tabs_of_window_.end() && window->second.erase(browser) && window->second.empty()) {
    tabs_of_window_.erase(window);
  }
  found->second.window = 0;
}

void HostMirrors::Close(int32_t browser) {
  auto found = tabs_.find(browser);
  if (found == tabs_.end()) return;
  Unplace(browser);
  if (found->second.profile) {
    auto profile = tabs_of_profile_.find(*found->second.profile);
    if (profile != tabs_of_profile_.end() && profile->second.erase(browser) && profile->second.empty()) {
      tabs_of_profile_.erase(profile);
    }
  }
  tabs_.erase(found);
}

void HostMirrors::WindowDestroyed(int64_t window) {
  auto found = tabs_of_window_.find(window);
  if (found != tabs_of_window_.end()) {
    for (int32_t browser : found->second) tabs_[browser].window = 0;
    tabs_of_window_.erase(found);
  }
  profile_of_window_.erase(window);
}

std::vector<int32_t> HostMirrors::TabsFor(uint16_t op, const MirrorEvent& event) const {
  std::vector<int32_t> tabs;
  const bool open = tabs_.count(event.browser) > 0;
  const int64_t window = event.a != 0 ? event.a : WindowOf(event.browser);
  switch (ScopeOf(op, event)) {
    case Scope::kTab:
      // A window-level event, or a browser cmux has no tab for (DevTools), names none.
      if (open) tabs.push_back(event.browser);
      return tabs;
    case Scope::kWindow:
      if (auto found = tabs_of_window_.find(window); found != tabs_of_window_.end()) Add(tabs, found->second);
      break;
    case Scope::kProfile: {
      std::optional<std::string> profile = ProfileOf(event.browser);
      if (!profile) {
        if (auto known = profile_of_window_.find(window); known != profile_of_window_.end()) profile = known->second;
      }
      if (profile) {
        if (auto found = tabs_of_profile_.find(*profile); found != tabs_of_profile_.end()) Add(tabs, found->second);
      } else if (auto found = tabs_of_window_.find(window); found != tabs_of_window_.end()) {
        Add(tabs, found->second);
      } else {
        // No tab says which profile changed: every open tab, as
        // CEFExtensionStores.refresh(window:browser:) falls back to refreshAll.
        for (const auto& [browser, tab] : tabs_) tabs.push_back(browser);
      }
      break;
    }
  }
  if (open && std::find(tabs.begin(), tabs.end(), event.browser) == tabs.end()) tabs.push_back(event.browser);
  std::sort(tabs.begin(), tabs.end());
  return tabs;
}

bool HostMirrors::KeyMatches(const std::vector<control::Field>& key, const std::vector<control::Field>& named,
                             uint32_t wildcards) {
  size_t next = 0;
  for (size_t i = 0; i < key.size(); ++i) {
    if (i < 32 && ((wildcards >> i) & 1u) != 0) continue;
    if (next >= named.size() || !(named[next] == key[i])) return false;
    ++next;
  }
  return next == named.size();
}

bool HostMirrors::Refresh(HostContext& ctx, uint16_t op, const std::vector<control::Field>& named,
                          uint32_t wildcards) const {
  const Producer* producer = ProducerOf(op);
  if (producer == nullptr) return false;
  if (producer->key == Key::kHost) {
    TlvReader r{std::vector<control::Field>()};
    ProduceMirror(ctx, op, r);
    return true;
  }
  auto refresh = [&](int32_t browser) {
    TlvWriter key;
    key.I32(browser);
    if (producer->key == Key::kTabIcon) key.I32(kExtActionIconPixels);
    if (!KeyMatches(key.fields(), named, wildcards)) return;
    TlvReader r(key.Take());
    ProduceMirror(ctx, op, r);
  };
  // A named tab (go_back's [browser_id]) costs that tab; a `*` tab (ext_set_enabled's) every open one.
  if ((wildcards & 1u) == 0) {
    if (!named.empty() && named[0].type == control::Type::kI32) {
      const auto browser = static_cast<int32_t>(named[0].integer);
      if (tabs_.count(browser)) refresh(browser);
    }
    return true;
  }
  for (const auto& entry : tabs_) refresh(entry.first);
  return true;
}

bool HostMirrors::Produce(HostContext& ctx, uint16_t op, const MirrorEvent& event) const {
  const Producer* producer = ProducerOf(op);
  if (producer == nullptr) return false;
  if (producer->key == Key::kHost) {
    int64_t reported = 0;
    if (EventValue(op, event, &reported)) {
      TlvWriter value;
      value.I32(static_cast<int32_t>(reported));
      ctx.PushMirror(op, TlvWriter(), value);
      return true;
    }
    TlvReader r{std::vector<control::Field>()};
    ProduceMirror(ctx, op, r);
    return true;
  }
  for (int32_t browser : TabsFor(op, event)) {
    TlvWriter key;
    key.I32(browser);
    if (producer->key == Key::kTabIcon) key.I32(kExtActionIconPixels);
    if (event.kind == CMUX_SHIM_BEFORE_CLOSE) {
      ctx.ForgetMirror(op, key);
      continue;
    }
    int64_t reported = 0;
    if (browser == event.browser && EventValue(op, event, &reported)) {
      TlvWriter value;
      value.I32(static_cast<int32_t>(reported));
      ctx.PushMirror(op, key, value);
      continue;
    }
    TlvReader r(key.Take());
    ProduceMirror(ctx, op, r);
  }
  return true;
}

}  // namespace cmux_host
