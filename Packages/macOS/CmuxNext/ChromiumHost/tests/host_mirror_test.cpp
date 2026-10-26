// Checks the Chromium Host's navigation, window and count mirrors
// (src/host_mirror.mm, task p01-process-016) through the dispatcher and
// fixtures/host_dispatch_subset.inc, against a fake shim whose values the
// test changes: every open tab's keys go out before each event that
// refreshes them, with no watch from cmux, so a cache applied in arrival
// order (as the remote shim applies a batch) already holds the new value
// when the event comes; event-carried values win over the shim's; a closed
// tab's keys are forgotten. Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"

namespace {

using cmux_host::HostContext;
using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::control::Type;
using cmux_host::tlv::Reader;
using cmux_host::tlv::Writer;

constexpr uint16_t kOpInitialize = 26, kOpCreateWindow = 28, kOpTabNavigationEntries = 32, kOpTabWindowId = 34,
                   kOpTabNavigationState = 65, kOpNavigationRestoreSupported = 67, kOpForeignBrowserCount = 91,
                   kOpLiveBrowserCount = 97, kOpWindowCount = 98;
constexpr uint16_t kOpEvent = 0x8001, kOpMirror = 0x8003;
constexpr int32_t kMinted = 1 << 20;
// cmux_tab_event_t (CEFForkTabEvent).
constexpr int kTabInserted = 0, kTabActivated = 1, kTabMoved = 2, kTabRemoved = 3, kTabWindowDestroyed = 6,
              kForeignBrowserBlocked = 9, kPopupWindowCreated = 10;

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
  std::map<int, int> window_of;
  int live = 0;
  int windows = 0;
  int foreign = 0;
  int window_id_reads = 0;
  int window_count_reads = 0;
} shim;

const char* Lookup(const std::map<int, std::string>& values, int browser) {
  auto found = values.find(browser);
  return found == values.end() ? nullptr : found->second.c_str();
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
  shim.window_of[3] = 11;
  shim.navigation_state[3] = "about:blank";
  Emit(CMUX_SHIM_AFTER_CREATED, 3, request, 11);  // OnAfterCreated inside the call
  return 1;
}
int cmux_shim_tab_add(int, const char*, int, int) { return 0; }
void cmux_shim_load_url(int, const char*) {}
void cmux_shim_set_focus(int, int) {}
int cmux_shim_devtools_call(int, const char*, const char*) { return 0; }
void cmux_shim_shutdown(void) {}
char* cmux_shim_tab_navigation_state(int browser_id) {
  const char* value = Lookup(shim.navigation_state, browser_id);
  return value ? strdup(value) : nullptr;
}
char* cmux_shim_tab_navigation_entries(int browser_id) {
  const char* value = Lookup(shim.navigation_entries, browser_id);
  return value ? strdup(value) : nullptr;
}
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

// A mirror value as text: "-" for no value (forget), "null" for a NULL string.
std::string ValueText(const std::vector<Field>& fields, size_t begin) {
  if (begin >= fields.size()) return "-";
  const Field& field = fields[begin];
  if (field.type == Type::kStr) return field.tag == cmux_host::tlv::kTagNull ? "null" : field.bytes;
  return std::to_string(field.integer);
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
                   delegate, views};
  std::function<void(const Message&)> on_event;

  Fixture() {
    shim = Shim();
    shim.host = &host;
    host.Attach(30, 1234);
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
    Message m;
    m.op = kOpInitialize;
    m.token = 1;
    m.fields = init.fields();
    host.OnMessages({m});
    host.Resume();
    sent.clear();
  }

  void Apply(const Message& m) {
    Reader r(m.fields);
    const int op = r.I32();
    const int key_count = r.I32();
    const int browser = key_count > 0 ? r.I32() : 0;
    const std::string value = ValueText(m.fields, 2 + static_cast<size_t>(key_count));
    if (value == "-") {
      cache.values.erase({op, browser});
    } else {
      cache.values[{op, browser}] = value;
    }
  }

  // "mirror <op> [browser] = <value>" and "event <kind> <browser> <request>", in order.
  std::vector<std::string> Sent() {
    std::vector<std::string> out;
    for (const Message& m : sent) {
      Reader r(m.fields);
      if (m.op == kOpMirror) {
        const int op = r.I32();
        const int key_count = r.I32();
        std::string text = "mirror " + std::to_string(op);
        for (int i = 0; i < key_count; ++i) text += " " + std::to_string(r.I32());
        out.push_back(text + " = " + ValueText(m.fields, 2 + static_cast<size_t>(key_count)));
      } else if (m.op == kOpEvent) {
        const int kind = r.I32(), browser = r.I32(), request = r.I32();
        out.push_back("event " + std::to_string(kind) + " " + std::to_string(browser) + " " +
                      std::to_string(request));
      }
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
};

std::string Join(const std::vector<std::string>& items) {
  std::string out;
  for (const std::string& item : items) out += (out.empty() ? "" : ", ") + item;
  return out;
}

void Expect(const std::vector<std::string>& got, const std::vector<std::string>& want, const char* what) {
  Check(got == want, std::string(what) + ": got [" + Join(got) + "], want [" + Join(want) + "]");
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
  f.Open(7, 11);
  Emit(CMUX_SHIM_ADDRESS, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "mirror 65 7 = s", "event 4 7 0"}, "ADDRESS");
  Check(f.cache.Read(kOpTabNavigationEntries, 7) == "e", "the Back/Forward entries are cached");
  Emit(CMUX_SHIM_TITLE, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "event 5 7 0"}, "TITLE refreshes the entries' titles only");
  Emit(CMUX_SHIM_LOADING_STATE, 7, 0);
  Expect(f.Sent(), {"mirror 32 7 = e", "mirror 65 7 = s", "event 7 7 0"}, "LOADING_STATE");
  Emit(CMUX_SHIM_LOAD_END, 7, 0);
  Expect(f.Sent(), {"mirror 65 7 = s", "event 9 7 0"}, "LOAD_END refreshes the state (page state) only");
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
  Expect(f.Sent(), {"mirror 91 = 0", "mirror 98 = 2", "event 16 0 6"},
         "a window-level event pushes no tab keys");
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
  f.Open(7, 11);
  Check(f.cache.Read(kOpTabNavigationState, 7) == "s", "open tab cached");
  --shim.live;
  shim.windows = 1;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 7, 0);
  Expect(f.Sent(),
         {"mirror 32 7 = -", "mirror 34 7 = -", "mirror 65 7 = -", "mirror 97 = 0", "mirror 98 = 1", "event 3 7 0"},
         "BEFORE_CLOSE forgets the tab's keys, refreshes the counts, then the event");
  Check(!f.cache.Read(kOpTabNavigationState, 7) && !f.cache.Read(kOpTabWindowId, 7), "the cache forgot the tab");
  Emit(CMUX_SHIM_ADDRESS, 7, 0);
  Expect(f.Sent(), {"event 4 7 0"}, "a closed tab gets no keys back");
  Emit(CMUX_SHIM_ADDRESS, 8, 0);
  Expect(f.Sent(), {"event 4 8 0"}, "a browser cmux has no tab for (DevTools) gets no keys");
}

// A tab cmux created: its keys use cmux's minted id, the shim reads Chromium's.
void MintedKeys() {
  Fixture f;
  Writer create;
  create.I32(kMinted);
  create.I32(42);
  create.ViewToken(9);
  create.I32(800);
  create.I32(600);
  create.Str("file:///probe.html");
  create.Str(nullptr);
  Message m;
  m.op = kOpCreateWindow;
  m.token = 20;
  m.fields = create.fields();
  f.host.OnMessages({m});
  Check(f.cache.Read(kOpTabNavigationState, kMinted) == "about:blank", "the minted id keys the new tab's state");
  Check(f.cache.Read(kOpTabWindowId, kMinted) == "11", "and its window");
  Check(!f.cache.Read(kOpTabNavigationState, 3), "Chromium's id never reaches cmux");
  shim.navigation_state[3] = "about:blank|file:///probe.html";
  Emit(CMUX_SHIM_LOAD_START, 3, 0);
  Check(f.cache.Read(kOpTabNavigationState, kMinted) == "about:blank|file:///probe.html",
        "LOAD_START of Chromium's browser refreshes the minted key");
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
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-mirror tests: ok");
  return EXIT_SUCCESS;
}
