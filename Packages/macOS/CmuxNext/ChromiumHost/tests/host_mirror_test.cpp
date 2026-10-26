// Checks the Chromium Host's tab and host mirrors (src/host_mirror.mm, tasks
// p01-process-016 and 017) through the dispatcher and a subset of the
// generated host_dispatch.inc (chromium-host-dispatch-subset.py: the current
// ops JSON's ids and refresh rows), against a fake shim whose values the test
// changes: every open tab's keys go out before each event that refreshes
// them, with no watch from cmux, so a cache applied in arrival order (as the
// remote shim applies a batch) already holds the new value when the event
// comes; event-carried values win over the shim's; a window's side panel and
// toolbar actions refresh every tab of the window, an extension change every
// tab of the profile; a closed tab's keys are forgotten. Run by
// scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"

#include "generated/host_dispatch.inc"

namespace {

using cmux_host::HostContext;
using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::control::Type;
using Reader = cmux_host::control::TlvReader;
using Writer = cmux_host::control::TlvWriter;
using cmux_host::control::kOpHello;
using cmux_host::control::kTagNull;
// The generated ids (host_dispatch.inc).
using cmux_host::kOpCreateWindow;
using cmux_host::kOpEvent;
using cmux_host::kOpExtActions;
using cmux_host::kOpExtCommands;
using cmux_host::kOpExtList;
using cmux_host::kOpForeignBrowserCount;
using cmux_host::kOpInitialize;
using cmux_host::kOpLiveBrowserCount;
using cmux_host::kOpMirror;
using cmux_host::kOpNavigationRestoreSupported;
using cmux_host::kOpOmniboxKeywords;
using cmux_host::kOpSidePanelState;
using cmux_host::kOpTabNavigationEntries;
using cmux_host::kOpTabNavigationState;
using cmux_host::kOpTabWindowId;
using cmux_host::kOpWindowCount;
using cmux_host::kExtActionIconPixels;

constexpr int32_t kMinted = 1 << 20;
// cmux_tab_event_t (CEFForkTabEvent).
constexpr int kTabInserted = 0, kTabActivated = 1, kTabMoved = 2, kTabRemoved = 3, kTabActionsChanged = 4,
              kTabWindowDestroyed = 6, kTabExtensionsChanged = 7, kForeignBrowserBlocked = 9,
              kPopupWindowCreated = 10, kTabSidePanelChanged = 12;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The fake shim's state, by Chromium's browser id.
struct Shim {
  HostContext* host = nullptr;
  std::map<int, std::string> navigation_state;
  std::map<int, std::string> navigation_entries;
  std::map<int, std::string> side_panel;
  std::map<int, std::string> ext_actions;
  std::map<int, std::string> ext_list;
  std::map<int, std::string> ext_commands;
  std::map<int, std::string> omnibox_keywords;
  std::map<int, int> window_of;
  std::vector<int> icon_px;  // every ext_actions read's icon size
  int live = 0;
  int windows = 0;
  int foreign = 0;
  int window_id_reads = 0;
  int window_count_reads = 0;
  // What the next create_window makes: Chromium's id and its window.
  int next_browser = 3;
  int next_window = 11;
} shim;

char* Lookup(const std::map<int, std::string>& values, int browser) {
  auto found = values.find(browser);
  return found == values.end() ? nullptr : strdup(found->second.c_str());
}

void Emit(int kind, int browser, int request, int64_t a = 0, int64_t b = 0) {
  HostContext::OnShimEvent(shim.host, kind, browser, request, a, b, "", "");
}

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
void cmux_shim_set_new_tab_page_url(const char*) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++shim.live;
  shim.window_of[shim.next_browser] = shim.next_window;
  shim.navigation_state[shim.next_browser] = "about:blank";
  Emit(CMUX_SHIM_AFTER_CREATED, shim.next_browser, request, shim.next_window);  // OnAfterCreated inside the call
  return 1;
}
int cmux_shim_tab_add(int, const char*, int, int) { return 0; }
int cmux_shim_tab_duplicate(int, int, int) { return 0; }
void cmux_shim_load_url(int, const char*) {}
void cmux_shim_set_focus(int, int) {}
int cmux_shim_devtools_call(int, const char*, const char*) { return 0; }
void cmux_shim_shutdown(void) {}
char* cmux_shim_tab_navigation_state(int browser_id) { return Lookup(shim.navigation_state, browser_id); }
char* cmux_shim_tab_navigation_entries(int browser_id) { return Lookup(shim.navigation_entries, browser_id); }
char* cmux_shim_side_panel_state(int browser_id) { return Lookup(shim.side_panel, browser_id); }
char* cmux_shim_ext_actions(int browser_id, int icon_px) {
  shim.icon_px.push_back(icon_px);
  return Lookup(shim.ext_actions, browser_id);
}
char* cmux_shim_ext_list(int browser_id) { return Lookup(shim.ext_list, browser_id); }
char* cmux_shim_ext_commands(int browser_id) { return Lookup(shim.ext_commands, browser_id); }
char* cmux_shim_omnibox_keywords(int browser_id) { return Lookup(shim.omnibox_keywords, browser_id); }
int cmux_shim_popup_window_bounds(int, int*, int*, int*, int*) { return 0; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_tab_window_id(int browser_id) {
  ++shim.window_id_reads;
  auto found = shim.window_of.find(browser_id);
  return found == shim.window_of.end() ? 0 : found->second;
}
int cmux_shim_navigation_restore_supported(void) { return 1; }
int cmux_shim_foreign_browser_count(void) { return shim.foreign; }
int cmux_shim_live_browser_count(void) { return shim.live; }
int cmux_shim_window_count(void) {
  ++shim.window_count_reads;
  return shim.windows;
}
}

namespace {

struct Delegate : cmux_host::HostDelegate {
  void Initialize(cmux_host::InitializeRequest) override {}
  void Quit() override {}
  void BrowserClosed() override {}
  void BadMessage(const std::string& what) override { bad.push_back(what); }
  std::vector<std::string> bad;
};

struct Views : cmux_host::PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
};

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

// One MIRROR as the remote shim decodes it: the op, the key's fields, and
// the value's fields (nullopt: no value, forget the key).
struct Pushed {
  int op = 0;
  std::vector<Field> key;
  std::optional<std::vector<Field>> value;
};

Pushed Decode(const Message& m) {
  Reader r(m.fields);
  Pushed p;
  p.op = r.I32();
  const std::string key = r.Bytes();
  const bool forget = r.AtEnd();
  const std::string value = forget ? std::string() : r.Bytes();
  Check(r.ok() && r.AtEnd(), "a MIRROR is op, key and an optional value");
  Check(cmux_host::control::DecodeFields(key, &p.key), "the key decodes");
  if (!forget) {
    std::vector<Field> fields;
    Check(cmux_host::control::DecodeFields(value, &fields), "the value decodes");
    p.value = std::move(fields);
  }
  return p;
}

// A mirror value as text: "-" for no value (forget), "null" for a NULL string.
std::string ValueText(const std::optional<std::vector<Field>>& value) {
  if (!value) return "-";
  if (value->empty()) return "";
  const Field& field = value->front();
  if (field.type == Type::kStr) return field.tag == kTagNull ? "null" : field.bytes;
  return std::to_string(field.integer);
}

std::string KeyText(const std::vector<Field>& key) {
  std::string text;
  for (const Field& field : key) text += " " + std::to_string(field.integer);
  return text;
}

// The remote shim's cache as it applies the host's messages in arrival order.
struct Cache {
  std::map<std::pair<int, int>, std::string> values;  // (op, browser or 0) -> value
  std::optional<std::string> Read(int op, int browser = 0) const {
    auto found = values.find({op, browser});
    if (found == values.end()) return std::nullopt;
    return found->second;
  }
};

struct Fixture {
  std::vector<Message> sent;
  Cache cache;
  Delegate delegate;
  Views views;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     if (m.op == kOpMirror) Apply(m);
                     if (m.op == kOpEvent && on_event) on_event(m);
                     return true;
                   },
                   delegate, views, [](const char*) -> void* { return nullptr; }};
  std::function<void(const Message&)> on_event;

  Fixture() {
    shim = Shim();
    shim.host = &host;
    host.Attach();
    Writer hello;
    hello.Str(cmux_host::kWireID);
    hello.Str(cmux_host::kShimAbiID);
    Writer init;
    init.Str("/fw");
    init.Str("/app");
    init.Str("/helper");
    init.Str("/root");
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host.OnMessages({Op(kOpHello, 0, hello), Op(kOpInitialize, 1, init)});
    host.Resume();
    sent.clear();
  }

  void Apply(const Message& m) {
    const Pushed p = Decode(m);
    const int browser = p.key.empty() ? 0 : static_cast<int>(p.key[0].integer);
    if (!p.value) {
      cache.values.erase({p.op, browser});
    } else {
      cache.values[{p.op, browser}] = ValueText(p.value);
    }
  }

  // "mirror <op> [key...] = <value>" and "event <kind> <browser> <request>", in order.
  std::vector<std::string> Sent() {
    std::vector<std::string> out;
    for (const Message& m : sent) {
      if (m.op == kOpMirror) {
        const Pushed p = Decode(m);
        out.push_back("mirror " + std::to_string(p.op) + KeyText(p.key) + " = " + ValueText(p.value));
      } else if (m.op == kOpEvent) {
        Reader r(m.fields);
        const int kind = r.I32(), browser = r.I32(), request = r.I32();
        out.push_back("event " + std::to_string(kind) + " " + std::to_string(browser) + " " +
                      std::to_string(request));
      }
    }
    sent.clear();
    return out;
  }

  // The (op, tab) of every MIRROR sent since the last call, for the ops in `ops`.
  std::set<std::pair<int, int>> Keys(const std::set<int>& ops) {
    std::set<std::pair<int, int>> out;
    for (const Message& m : sent) {
      if (m.op != kOpMirror) continue;
      const Pushed p = Decode(m);
      if (ops.count(p.op) && !p.key.empty()) out.insert({p.op, static_cast<int>(p.key[0].integer)});
    }
    sent.clear();
    return out;
  }

  // A tab Chromium made (no minted id): AFTER_CREATED in window `window`.
  void Open(int browser, int window) {
    ++shim.live;
    shim.window_of[browser] = window;
    Emit(CMUX_SHIM_AFTER_CREATED, browser, 0, window);
    sent.clear();
  }

  // A window cmux made for `profile` (nullptr: the default profile): minted
  // id `minted`, Chromium's `browser` in Chromium window `window`.
  void Create(int32_t minted, int browser, int window, const char* profile) {
    shim.next_browser = browser;
    shim.next_window = window;
    Writer create;
    create.I32(minted);
    create.I32(42 + (minted - kMinted));  // the request: never 0 (a tab Chromium made)
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("file:///probe.html");
    create.Str(profile);
    host.OnMessages({Op(kOpCreateWindow, 20, create)});
    sent.clear();
  }
};

std::string Join(const std::vector<std::string>& items) {
  std::string out;
  for (const std::string& item : items) out += (out.empty() ? "" : ", ") + item;
  return out;
}

void Expect(const std::vector<std::string>& got, const std::vector<std::string>& want, const char* what) {
  Check(got == want, std::string(what) + ": got [" + Join(got) + "], want [" + Join(want) + "]");
}

std::string KeysText(const std::set<std::pair<int, int>>& keys) {
  std::string out;
  for (const auto& [op, tab] : keys) out += (out.empty() ? "" : ", ") + std::to_string(op) + ":" + std::to_string(tab);
  return out;
}

// The acceptance row: a read of tab_navigation_state in the turn that sees
// LOAD_START gets the new entry, with no watch from cmux.
void LoadStartCarriesTheNewEntry() {
  Fixture f;
  shim.navigation_state[7] = "a";
  f.Open(7, 11);
  Check(f.cache.Read(kOpTabNavigationState, 7) == "a", "AFTER_CREATED fills the new tab's navigation state");
  shim.navigation_state[7] = "a|b";
  std::optional<std::string> read_at_event;
  f.on_event = [&](const Message& m) {
    Reader r(m.fields);
    if (r.I32() == CMUX_SHIM_LOAD_START) read_at_event = f.cache.Read(kOpTabNavigationState, 7);
  };
  Emit(CMUX_SHIM_LOAD_START, 7, 0);
  Check(read_at_event == "a|b", "the cache holds the new entry when LOAD_START arrives, got " +
                                    read_at_event.value_or("nothing"));
  Expect(f.Sent(), {"mirror 32 7 = null", "mirror 65 7 = a|b", "event 8 7 0"},
         "LOAD_START: entries and state, then the event");
}

// Each key goes out on exactly its refresh events (chromium-host-ops.json).
void EachKeyOnItsEvents() {
  Fixture f;
  shim.navigation_state[7] = "s";
  shim.navigation_entries[7] = "e";
  shim.ext_actions[7] = "[]";
  f.Open(7, 11);
  Emit(CMUX_SHIM_ADDRESS, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "mirror 60 7 56 = []", "mirror 65 7 = s", "event 4 7 0"}, "ADDRESS");
  Check(f.cache.Read(kOpTabNavigationEntries, 7) == "e", "the Back/Forward entries are cached");
  Emit(CMUX_SHIM_TITLE, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "event 5 7 0"}, "TITLE refreshes the entries' titles only");
  Emit(CMUX_SHIM_LOADING_STATE, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "mirror 65 7 = s", "event 7 7 0"}, "LOADING_STATE");
  Emit(CMUX_SHIM_LOAD_END, 7, 0);
  Expect(f.Sent(), {"mirror 60 7 56 = []", "mirror 65 7 = s", "event 9 7 0"},
         "LOAD_END refreshes the toolbar actions and the state (page state)");
  Emit(CMUX_SHIM_PROGRESS, 7, 0);
  Expect(f.Sent(), {"event 11 7 0"}, "PROGRESS refreshes nothing");
}

// The window id comes from the event where the event carries it.
void WindowIdFromTheEvent() {
  Fixture f;
  shim.window_of[7] = 99;  // what the fork would say: the event's value wins
  ++shim.live;
  shim.window_id_reads = 0;
  Emit(CMUX_SHIM_AFTER_CREATED, 7, 0, 11);
  Check(f.cache.Read(kOpTabWindowId, 7) == "11", "AFTER_CREATED's window");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabMoved, 12);
  Check(f.cache.Read(kOpTabWindowId, 7) == "12", "TAB_EVENT moved's window");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabInserted, 13);
  Check(f.cache.Read(kOpTabWindowId, 7) == "13", "TAB_EVENT inserted's window");
  Check(shim.window_id_reads == 0, "no shim read when the event carries the window");
  f.Sent();
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabActivated, 13);
  Expect(f.Sent(), {"event 16 7 1"}, "activation moves no tab");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabRemoved, 13);
  Check(shim.window_id_reads == 1 && f.cache.Read(kOpTabWindowId, 7) == "99",
        "TAB_EVENT removed reads the tab's window from the fork");
}

// The counts: the remaining windows from the event, the rest from the shim.
void Counts() {
  Fixture f;
  Check(f.cache.Read(kOpNavigationRestoreSupported) == "1", "the fork capability went out at the hello");
  shim.windows = 3;
  f.Open(7, 11);
  Check(f.cache.Read(kOpWindowCount) == "3" && f.cache.Read(kOpLiveBrowserCount) == "1",
        "AFTER_CREATED refreshes the window and browser counts");
  shim.window_count_reads = 0;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabWindowDestroyed, 11, 2);
  Check(f.cache.Read(kOpWindowCount) == "2" && shim.window_count_reads == 0,
        "window destroyed: the remaining count from the event, not the fork's (it still counts that window)");
  Expect(f.Sent(), {"mirror 91 = 0", "mirror 98 = 2", "event 16 0 6"}, "a window-level event pushes no tab keys");
  shim.foreign = 1;
  shim.windows = 4;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kForeignBrowserBlocked, 0, 1);
  Check(f.cache.Read(kOpForeignBrowserCount) == "1" && f.cache.Read(kOpWindowCount) == "4",
        "a blocked foreign Browser refreshes the foreign and window counts");
  shim.windows = 5;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kPopupWindowCreated, 0, 1);
  Check(f.cache.Read(kOpWindowCount) == "5", "a popup window refreshes the window count");
}

// BEFORE_CLOSE forgets the tab's keys; later events push none for it.
void CloseForgets() {
  Fixture f;
  shim.navigation_state[7] = "s";
  shim.side_panel[7] = "{}";
  f.Open(7, 11);
  Check(f.cache.Read(kOpTabNavigationState, 7) == "s" && f.cache.Read(kOpSidePanelState, 7) == "{}",
        "open tab cached");
  --shim.live;
  shim.windows = 1;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 7, 0);
  Expect(f.Sent(),
         {"mirror 32 7 = -", "mirror 34 7 = -", "mirror 60 7 56 = -", "mirror 65 7 = -", "mirror 68 7 = -",
          "mirror 76 7 = -", "mirror 85 7 = -", "mirror 88 7 = -", "mirror 97 = 0", "mirror 98 = 1", "event 3 7 0"},
         "BEFORE_CLOSE forgets the tab's keys, refreshes the counts, then the event");
  Check(!f.cache.Read(kOpTabNavigationState, 7) && !f.cache.Read(kOpTabWindowId, 7) &&
            !f.cache.Read(kOpSidePanelState, 7),
        "the cache forgot the tab");
  Emit(CMUX_SHIM_ADDRESS, 7, 0);
  Expect(f.Sent(), {"event 4 7 0"}, "a closed tab gets no keys back");
  Emit(CMUX_SHIM_ADDRESS, 8, 0);
  Expect(f.Sent(), {"event 4 8 0"}, "a browser cmux has no tab for (DevTools) gets no keys");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabSidePanelChanged, 11, 1);
  Expect(f.Sent(), {"event 16 7 12"}, "a window with no open tab left gets no side panel keys");
}

// A tab cmux created: its keys use cmux's minted id, the shim reads Chromium's.
void MintedKeys() {
  Fixture f;
  f.Create(kMinted, 3, 11, nullptr);
  Check(f.cache.Read(kOpTabNavigationState, kMinted) == "about:blank", "the minted id keys the new tab's state");
  Check(f.cache.Read(kOpTabWindowId, kMinted) == "11", "and its window");
  Check(!f.cache.Read(kOpTabNavigationState, 3), "Chromium's id never reaches cmux");
  shim.navigation_state[3] = "about:blank|file:///probe.html";
  Emit(CMUX_SHIM_LOAD_START, 3, 0);
  Check(f.cache.Read(kOpTabNavigationState, kMinted) == "about:blank|file:///probe.html",
        "LOAD_START of Chromium's browser refreshes the minted key");
  Check(f.delegate.bad.empty(), "no bad message");
}

// Task 017's producers: a value for a tab cmux never asked about, with no
// watch, and a read in the event's turn gets it.
void SitePanelAndExtensionsWithNoWatch() {
  Fixture f;
  shim.side_panel[7] = "{\"visible\":false}";
  shim.ext_actions[7] = "[{\"id\":\"a\"}]";
  shim.ext_list[7] = "[\"a\"]";
  shim.ext_commands[7] = "[\"cmd\"]";
  shim.omnibox_keywords[7] = "[\"kw\"]";
  f.Open(7, 11);
  Check(f.cache.Read(kOpSidePanelState, 7) == "{\"visible\":false}", "AFTER_CREATED pushes the side panel");
  Check(f.cache.Read(kOpExtActions, 7) == "[{\"id\":\"a\"}]", "and the toolbar actions");
  Check(f.cache.Read(kOpExtList, 7) == "[\"a\"]" && f.cache.Read(kOpExtCommands, 7) == "[\"cmd\"]" &&
            f.cache.Read(kOpOmniboxKeywords, 7) == "[\"kw\"]",
        "and the extensions, shortcuts and omnibox keywords");
  Check(!shim.icon_px.empty() &&
            std::all_of(shim.icon_px.begin(), shim.icon_px.end(), [](int px) { return px == kExtActionIconPixels; }),
        "every ext_actions read is at CEFExtensionAction.iconPixels");

  shim.ext_actions[7] = "[{\"id\":\"a\",\"badge\":\"3\"}]";
  std::optional<std::string> read_at_event;
  f.on_event = [&](const Message& m) {
    Reader r(m.fields);
    if (r.I32() == CMUX_SHIM_LOAD_END) read_at_event = f.cache.Read(kOpExtActions, 7);
  };
  Emit(CMUX_SHIM_LOAD_END, 7, 200);
  Check(read_at_event == "[{\"id\":\"a\",\"badge\":\"3\"}]",
        "a read of the toolbar actions in LOAD_END's turn gets the page's badge");
  Check(f.delegate.bad.empty(), "no bad message");
}

// Which tabs each (mirror, event) row of the generated kMirrorRefreshes names,
// for 017's producers. Every row of those mirrors must be here: a row added to
// the ops JSON fails until its scope is written down.
enum class Names { kTab, kWindow, kProfile };
struct ScopeRow {
  uint16_t op;
  int kind;
  int request;  // -1: any
  Names names;
};
const ScopeRow kExpected[] = {
    {kOpExtActions, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {kOpExtActions, CMUX_SHIM_TAB_EVENT, kTabActionsChanged, Names::kWindow},
    {kOpExtActions, CMUX_SHIM_ADDRESS, -1, Names::kTab},
    {kOpExtActions, CMUX_SHIM_LOAD_END, -1, Names::kTab},
    {kOpExtActions, CMUX_SHIM_TAB_EVENT, kTabInserted, Names::kTab},
    {kOpExtActions, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {kOpExtList, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {kOpExtList, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {kOpExtList, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {kOpExtCommands, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {kOpExtCommands, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {kOpExtCommands, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {kOpSidePanelState, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabInserted, Names::kTab},
    {kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabMoved, Names::kTab},
    {kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabSidePanelChanged, Names::kWindow},
    {kOpSidePanelState, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {kOpOmniboxKeywords, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {kOpOmniboxKeywords, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {kOpOmniboxKeywords, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
};

// For each row: profile A has minted tabs 1 and 2 in window 11, minted tab 5
// and a tab Chromium made (104) in window 13; profile B has minted tab 3 in
// window 12. The event comes from tab 1 in window 11; the row's mirror must go
// out for exactly the tabs its scope names.
void RefreshRowsMatchTheirScope() {
  const std::set<int> ops = {kOpExtActions, kOpExtList, kOpExtCommands, kOpSidePanelState, kOpOmniboxKeywords};
  std::set<std::tuple<int, int, int>> generated;
  for (const cmux_host::MirrorRefresh& row : cmux_host::kMirrorRefreshes) {
    if (ops.count(row.op)) generated.insert({row.op, row.kind, row.request});
  }
  std::set<std::tuple<int, int, int>> expected;
  for (const ScopeRow& row : kExpected) expected.insert({row.op, row.kind, row.request});
  Check(generated == expected, "the ops JSON's refresh rows of 017's mirrors are the rows this test scopes");

  const int32_t a1 = kMinted + 1, a2 = kMinted + 2, b3 = kMinted + 3, a5 = kMinted + 5;
  for (const ScopeRow& row : kExpected) {
    Fixture f;
    f.Create(a1, 101, 11, "/profiles/a");
    f.Create(a2, 102, 11, "/profiles/a");
    f.Create(b3, 103, 12, "/profiles/b");
    // A tab Chromium made in window 13 takes the profile of the minted tab there.
    f.Create(a5, 105, 13, "/profiles/a");
    f.Open(104, 13);
    std::set<int32_t> names;
    switch (row.names) {
      case Names::kTab:
        names = {a1};
        break;
      case Names::kWindow:
        names = {a1, a2};
        break;
      case Names::kProfile:
        names = {a1, a2, a5, 104};
        break;
    }
    const int request = row.request < 0 ? 0 : row.request;
    if (row.kind == CMUX_SHIM_AFTER_CREATED) {
      // A new tab in window 11 of profile A.
      f.Create(a1 + 100, 106, 11, "/profiles/a");
      names = {a1 + 100};
      // Create cleared what it sent; check the cache instead.
      Check(f.cache.Read(row.op, a1 + 100).has_value(),
            "AFTER_CREATED pushes mirror " + std::to_string(row.op) + " for the new tab");
      continue;
    }
    Emit(row.kind, 101, request, 11);
    std::set<std::pair<int, int>> got = f.Keys({row.op});
    std::set<std::pair<int, int>> want;
    for (int32_t tab : names) want.insert({row.op, tab});
    Check(got == want, "mirror " + std::to_string(row.op) + " at event " + std::to_string(row.kind) + ":" +
                           std::to_string(request) + ": got [" + KeysText(got) + "], want [" + KeysText(want) + "]");
  }
}

// The tab -> window and window -> profile records behind the scopes.
void WindowsAndProfilesFollowTheTabs() {
  Fixture f;
  f.Create(kMinted + 1, 101, 11, "/profiles/a");
  f.Create(kMinted + 2, 102, 12, "/profiles/b");
  // A popup Chromium places later: no window at AFTER_CREATED, then inserted into window 11.
  ++shim.live;
  Emit(CMUX_SHIM_AFTER_CREATED, 103, 0, 0);
  Emit(CMUX_SHIM_TAB_EVENT, 103, kTabInserted, 11);
  f.sent.clear();
  Emit(CMUX_SHIM_TAB_EVENT, 101, kTabSidePanelChanged, 11, 1);
  Check(f.Keys({kOpSidePanelState}) == std::set<std::pair<int, int>>({{kOpSidePanelState, kMinted + 1}, {kOpSidePanelState, 103}}),
        "a placed popup joins its window's side panel refresh");
  Emit(CMUX_SHIM_TAB_EVENT, 101, kTabExtensionsChanged, 11);
  Check(f.Keys({kOpExtList}) == std::set<std::pair<int, int>>({{kOpExtList, kMinted + 1}, {kOpExtList, 103}}),
        "the popup takes its window's profile; profile B's tab is not refreshed");

  // The popup moves to window 12 (profile B: a window has one profile, the popup keeps its own).
  Emit(CMUX_SHIM_TAB_EVENT, 103, kTabRemoved, 11);
  Emit(CMUX_SHIM_TAB_EVENT, 103, kTabInserted, 12);
  f.sent.clear();
  Emit(CMUX_SHIM_TAB_EVENT, 101, kTabSidePanelChanged, 11, 1);
  Check(f.Keys({kOpSidePanelState}) == std::set<std::pair<int, int>>({{kOpSidePanelState, kMinted + 1}}),
        "a moved tab leaves its old window's refresh");
  Emit(CMUX_SHIM_TAB_EVENT, 102, kTabSidePanelChanged, 12, 1);
  Check(f.Keys({kOpSidePanelState}) == std::set<std::pair<int, int>>({{kOpSidePanelState, kMinted + 2}, {kOpSidePanelState, 103}}),
        "and joins its new window's");
  // A removed event of the old window after the tab moved on keeps the new one.
  Emit(CMUX_SHIM_TAB_EVENT, 103, kTabRemoved, 11);
  f.sent.clear();
  Emit(CMUX_SHIM_TAB_EVENT, 102, kTabSidePanelChanged, 12, 1);
  Check(f.Keys({kOpSidePanelState}).count({kOpSidePanelState, 103}) == 1, "a stale removed keeps the current window");

  // Window 12 is destroyed: its tabs leave it.
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabWindowDestroyed, 12, 1);
  f.sent.clear();
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabSidePanelChanged, 12, 1);
  Check(f.Keys({kOpSidePanelState}).empty(), "a destroyed window names no tab");
  Check(f.delegate.bad.empty(), "no bad message");
}

}  // namespace

int main() {
  LoadStartCarriesTheNewEntry();
  EachKeyOnItsEvents();
  WindowIdFromTheEvent();
  Counts();
  CloseForgets();
  MintedKeys();
  SitePanelAndExtensionsWithNoWatch();
  RefreshRowsMatchTheirScope();
  WindowsAndProfilesFollowTheTabs();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-mirror tests: ok");
  return EXIT_SUCCESS;
}
