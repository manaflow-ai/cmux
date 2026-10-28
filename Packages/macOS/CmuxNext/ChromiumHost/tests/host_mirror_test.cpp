// Checks the Chromium Host's tab and host mirrors (src/host_mirror.mm)
// end to end: the real dispatcher
// (src/host_dispatch.mm, the generated cases) with a fake shim on one end of a
// socket pair, the real remote shim (client/remote_shim.mm, loaded as the
// shared library cmux loads) on the other, and every read made through the
// remote shim's exports, as cmux's Swift code makes it. So the wire both ends
// speak is the one this checks: each side's HELLO, MIRROR's EncodeFields key
// and value, a forget with no value.
//
//   - a read of tab_navigation_state in the LOAD_START callback has the new
//     entry, with no watch from cmux (the acceptance of task 016);
//   - one navigation reads and pushes the history twice (ADDRESS, LOAD_START),
//     never at TITLE, LOAD_END or LOADING_STATE: the bytes per navigation;
//   - a history over the frame bound is forgotten, never served stale;
//   - event-carried windows and counts; BEFORE_CLOSE forgets the tab;
//   - the side panel, toolbar actions, extensions, shortcuts and omnibox
//     keywords of a tab cmux never asked about are in the cache in the turn
//     of their events (task 017), and each refresh row of those mirrors in the
//     generated kMirrorRefreshes names exactly the tabs of its scope: the
//     event's tab, its Chromium window's tabs, or its profile's tabs.
// Built and run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <thread>
#include <utility>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "remote_shim_runtime.h"

#include "generated/host_dispatch.inc"

namespace {

using cmux_host::HostContext;
using cmux_host::control::Channel;
using cmux_host::control::End;
using cmux_host::control::Field;
using cmux_host::control::Message;

// cmux_tab_event_t (CEFForkTabEvent).
constexpr int kTabInserted = 0, kTabActivated = 1, kTabMoved = 2, kTabRemoved = 3, kTabActionsChanged = 4,
              kTabWindowDestroyed = 6, kTabExtensionsChanged = 7, kForeignBrowserBlocked = 9,
              kPopupWindowCreated = 10, kTabSidePanelChanged = 12;
constexpr int kWindow = 11;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The test thread is both processes' main thread: tasks from both channels run here, in order.
std::mutex queue_mutex;
std::deque<std::function<void()>> queue;

void PostTask(std::function<void()> task) {
  std::lock_guard<std::mutex> lock(queue_mutex);
  queue.push_back(std::move(task));
}

void PostMain(void*, cmux_remote_main_task_fn run, void* task) {
  PostTask([run, task] { run(task); });
}

bool PumpUntil(const std::function<bool()>& done) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!done()) {
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      tasks.swap(queue);
    }
    for (std::function<void()>& task : tasks) task();
    if (std::chrono::steady_clock::now() > deadline) return false;
    if (tasks.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

// The remote shim's exports, as cmux binds them (CEFShimLibrary).
struct Client {
  decltype(&cmux_remote_shim_configure) configure;
  decltype(&cmux_remote_shim_attach) attach;
  decltype(&cmux_remote_shim_detach) detach;
  decltype(&cmux_remote_shim_host_has_export) host_has_export;
  decltype(&cmux_shim_initialize) initialize;
  decltype(&cmux_shim_create_window) create_window;
  decltype(&cmux_shim_load_url) load_url;
  decltype(&cmux_shim_tab_navigation_state) navigation_state;
  decltype(&cmux_shim_tab_navigation_entries) navigation_entries;
  decltype(&cmux_shim_tab_window_id) window_id;
  decltype(&cmux_shim_window_count) window_count;
  decltype(&cmux_shim_live_browser_count) live_browser_count;
  decltype(&cmux_shim_foreign_browser_count) foreign_browser_count;
  decltype(&cmux_shim_navigation_restore_supported) navigation_restore_supported;
  decltype(&cmux_shim_side_panel_state) side_panel_state;
  decltype(&cmux_shim_ext_actions) ext_actions;
  decltype(&cmux_shim_ext_list) ext_list;
  decltype(&cmux_shim_ext_commands) ext_commands;
  decltype(&cmux_shim_omnibox_keywords) omnibox_keywords;
  decltype(&cmux_shim_renderer_client_ids) renderer_client_ids;
  decltype(&cmux_shim_free) free;

  // A string read: nullopt for NULL (no value in the cache).
  std::optional<std::string> Take(char* value) const {
    if (value == nullptr) return std::nullopt;
    std::string out(value);
    free(value);
    return out;
  }
  std::optional<std::string> State(int browser) const { return Take(navigation_state(browser)); }
  std::optional<std::string> Entries(int browser) const { return Take(navigation_entries(browser)); }
};

template <typename T>
void Bind(void* library, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(library, name));
  if (*out == nullptr) {
    std::fprintf(stderr, "FAIL: the remote shim has no %s\n", name);
    std::exit(EXIT_FAILURE);
  }
}

Client LoadClient() {
  void* library = dlopen(CMUX_REMOTE_SHIM_PATH, RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    std::fprintf(stderr, "FAIL: %s\n", dlerror());
    std::exit(EXIT_FAILURE);
  }
  Client c{};
  Bind(library, "cmux_remote_shim_configure", &c.configure);
  Bind(library, "cmux_remote_shim_attach", &c.attach);
  Bind(library, "cmux_remote_shim_detach", &c.detach);
  Bind(library, "cmux_remote_shim_host_has_export", &c.host_has_export);
  Bind(library, "cmux_shim_initialize", &c.initialize);
  Bind(library, "cmux_shim_create_window", &c.create_window);
  Bind(library, "cmux_shim_load_url", &c.load_url);
  Bind(library, "cmux_shim_tab_navigation_state", &c.navigation_state);
  Bind(library, "cmux_shim_tab_navigation_entries", &c.navigation_entries);
  Bind(library, "cmux_shim_tab_window_id", &c.window_id);
  Bind(library, "cmux_shim_window_count", &c.window_count);
  Bind(library, "cmux_shim_live_browser_count", &c.live_browser_count);
  Bind(library, "cmux_shim_foreign_browser_count", &c.foreign_browser_count);
  Bind(library, "cmux_shim_navigation_restore_supported", &c.navigation_restore_supported);
  Bind(library, "cmux_shim_side_panel_state", &c.side_panel_state);
  Bind(library, "cmux_shim_ext_actions", &c.ext_actions);
  Bind(library, "cmux_shim_ext_list", &c.ext_list);
  Bind(library, "cmux_shim_ext_commands", &c.ext_commands);
  Bind(library, "cmux_shim_omnibox_keywords", &c.omnibox_keywords);
  Bind(library, "cmux_shim_renderer_client_ids", &c.renderer_client_ids);
  Bind(library, "cmux_shim_free", &c.free);
  return c;
}

Client client;

// The host's fake shim, by Chromium's browser id.
struct Shim {
  HostContext* host = nullptr;
  std::map<int, std::vector<std::string>> history;
  std::map<int, int> window_of;
  size_t state_padding = 0;  // bytes of page state each read adds
  // Task 017's values, by Chromium's browser id; every ext_actions read's icon size.
  std::map<int, std::string> side_panel, ext_actions, ext_list, ext_commands, omnibox_keywords;
  std::vector<int> icon_px;
  // Task 225: each browser's frames' renderer client ids.
  std::map<int, std::vector<int>> renderers;
  int next_browser = 3;
  int next_window = kWindow;  // the window the next create_window makes
  int live = 0;
  int windows = 0;
  int foreign = 0;
  int state_reads = 0;
  int entries_reads = 0;
  int window_id_reads = 0;
  int window_count_reads = 0;
} shim;

void Emit(int kind, int browser, int request, int64_t a = 0, int64_t b = 0, const char* s1 = "") {
  HostContext::OnShimEvent(shim.host, kind, browser, request, a, b, s1, "");
}

std::string Joined(int browser) {
  std::string out;
  for (const std::string& url : shim.history[browser]) out += (out.empty() ? "" : "|") + url;
  return out;
}

int TabSetFrozen(int, int) { return 1; }

void* Resolve(const char* name) {
  return std::strcmp(name, "cmux_shim_tab_set_frozen") == 0 ? reinterpret_cast<void*>(&TabSetFrozen) : nullptr;
}

}  // namespace

extern "C" {
int cmux_shim_create_window(int request, void*, int, int, const char* url, const char*) {
  const int browser = shim.next_browser++;
  ++shim.live;
  shim.window_of[browser] = shim.next_window;
  shim.history[browser] = {url ? url : ""};
  Emit(CMUX_SHIM_AFTER_CREATED, browser, request, shim.next_window);  // OnAfterCreated inside the call
  return 1;
}
// One cross-document navigation, as Chromium reports it: later, in a task of
// the UI thread, never inside the call (so after its ack).
void cmux_shim_load_url(int browser_id, const char* url) {
  PostTask([browser_id, committed = std::string(url)] {
    shim.history[browser_id].push_back(committed);
    Emit(CMUX_SHIM_LOADING_STATE, browser_id, 0, 1);
    Emit(CMUX_SHIM_ADDRESS, browser_id, 0, 0, 0, committed.c_str());
    Emit(CMUX_SHIM_LOAD_START, browser_id, 0, 0, 0, committed.c_str());
    Emit(CMUX_SHIM_TITLE, browser_id, 0, 0, 0, "title");
    Emit(CMUX_SHIM_LOAD_END, browser_id, 0, 200);
    Emit(CMUX_SHIM_LOADING_STATE, browser_id, 0, 0);
  });
}
char* cmux_shim_tab_navigation_state(int browser_id) {
  ++shim.state_reads;
  if (!shim.history.count(browser_id)) return nullptr;
  return strdup((Joined(browser_id) + std::string(shim.state_padding, '#')).c_str());
}
char* cmux_shim_tab_navigation_entries(int browser_id) {
  ++shim.entries_reads;
  if (!shim.history.count(browser_id)) return nullptr;
  return strdup(("entries " + Joined(browser_id)).c_str());
}
char* ValueOf(const std::map<int, std::string>& values, int browser) {
  auto found = values.find(browser);
  return found == values.end() ? nullptr : strdup(found->second.c_str());
}
char* cmux_shim_side_panel_state(int browser_id) { return ValueOf(shim.side_panel, browser_id); }
char* cmux_shim_ext_actions(int browser_id, int icon_px) {
  shim.icon_px.push_back(icon_px);
  return ValueOf(shim.ext_actions, browser_id);
}
char* cmux_shim_ext_list(int browser_id) { return ValueOf(shim.ext_list, browser_id); }
char* cmux_shim_ext_commands(int browser_id) { return ValueOf(shim.ext_commands, browser_id); }
char* cmux_shim_omnibox_keywords(int browser_id) { return ValueOf(shim.omnibox_keywords, browser_id); }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_renderer_client_ids(int browser_id, int* out, int capacity) {
  int count = 0;
  for (const int id : shim.renderers[browser_id]) {
    if (count < capacity) out[count++] = id;
  }
  return count;
}
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

struct World;
World* current = nullptr;
bool initialized = false;
bool ready = false;  // the host's HELLO reached the remote shim
int ended = -1;

struct Delegate : cmux_host::HostDelegate {
  std::function<void()> resume;
  bool resumed = false;
  std::vector<std::string> bad;
  void Initialize(cmux_host::InitializeRequest) override {
    // browser_host_main.mm runs cmux_shim_initialize, then Resume in a task.
    PostTask([this] {
      resume();
      resumed = true;
    });
  }
  void Quit() override {}
  void BrowserClosed() override {}
  void BadMessage(const std::string& what) override { bad.push_back(what); }
};

struct Views : cmux_host::PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const cmux_host::PageGeometry&) override {}
};

struct Event {
  int kind, browser, request;
};

// One host and its attached remote shim.
struct World {
  Delegate delegate;
  Views views;
  std::unique_ptr<Channel> channel;
  // The host's MIRROR frames: op and body bytes, and (op, the key's first field).
  std::vector<std::pair<int, size_t>> mirrors;
  std::vector<std::pair<int, int>> mirror_keys;
  std::vector<Event> events;
  std::function<void(const Event&)> on_event;
  HostContext host{[this](const Message& m) {
                     if (m.op == cmux_host::kOpMirror) Record(m);
                     return channel && channel->Send(m);
                   },
                   delegate, views, &Resolve};

  World() {
    shim = Shim();
    shim.host = &host;
    current = this;
    ready = false;
    ended = -1;
    delegate.resume = [this] { host.Resume(); };
    int pair[2];
    Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
    channel = std::make_unique<Channel>(
        pair[1], &PostTask, [this](std::vector<Message> batch) { host.OnMessages(std::move(batch)); },
        [](End) {});
    host.Attach();  // browser_host_main.mm: before the first message
    Check(client.attach(pair[0], nullptr, nullptr) == 1, "the remote shim attaches");
    if (!initialized) {
      const char* switches[] = {nullptr};
      Check(client.initialize("/fw", "/app", "/helper", "/root", nullptr, 0, nullptr, nullptr, switches, nullptr,
                              nullptr, &OnEvent, nullptr) == 1,
            "initialize is sent");
      initialized = true;  // a later attach sends INITIALIZE again on its own
    }
    Check(PumpUntil([this] { return ready && delegate.resumed; }), "the hellos and initialize go through");
  }

  ~World() {
    client.detach();
    channel->Close();
    channel.reset();
    current = nullptr;
  }

  void Record(const Message& m) {
    size_t bytes = 0;
    for (const Field& field : m.fields) bytes += cmux_host::control::kFieldHeaderSize + field.bytes.size();
    const int op = static_cast<int>(m.fields.empty() ? 0 : m.fields[0].integer);
    mirrors.emplace_back(op, bytes);
    std::vector<Field> key;
    if (m.fields.size() > 1 && cmux_host::control::DecodeFields(m.fields[1].bytes, &key) && !key.empty()) {
      mirror_keys.emplace_back(op, static_cast<int>(key[0].integer));
    }
  }

  // The tabs whose `op` key went out since the last call.
  std::set<int> KeysOf(int op) {
    std::set<int> out;
    for (const auto& [mirror, tab] : mirror_keys) {
      if (mirror == op) out.insert(tab);
    }
    mirror_keys.clear();
    return out;
  }

  // Runs until the remote shim saw an event of `kind`.
  void PumpUntilEvent(int kind) {
    const size_t seen = events.size();
    Check(PumpUntil([&] {
            for (size_t i = seen; i < events.size(); ++i) {
              if (events[i].kind == kind) return true;
            }
            return false;
          }),
          "event " + std::to_string(kind) + " reached the remote shim");
  }

  // A window cmux creates through the remote shim, in Chromium window
  // `window` of `profile` (nullptr: the default); returns cmux's (minted) id.
  int CreateWindow(const char* url, int window = kWindow, const char* profile = nullptr) {
    shim.next_window = window;
    Check(client.create_window(++requests, nullptr, 800, 600, url, profile) == 1, "create_window is sent");
    PumpUntilEvent(CMUX_SHIM_AFTER_CREATED);
    return events.back().browser;
  }
  int requests = 41;

  size_t MirrorBytes(int op) const {
    size_t bytes = 0;
    for (const auto& [mirror, size] : mirrors) bytes += mirror == op ? size : 0;
    return bytes;
  }
  int MirrorCount(int op) const {
    int count = 0;
    for (const auto& entry : mirrors) count += entry.first == op ? 1 : 0;
    return count;
  }

  static void OnEvent(void*, int kind, int browser, int request, int64_t, int64_t, const char*, const char*) {
    if (current == nullptr) return;
    const Event event{kind, browser, request};
    if (current->on_event) current->on_event(event);
    current->events.push_back(event);
  }
};

void OnReady(void*) { ready = true; }
void OnEnded(void*, int reason) { ended = reason; }

// The acceptance: a read of tab_navigation_state in the LOAD_START callback
// gets the new entry, with no watch from cmux.
void LoadStartReadsTheNewEntry() {
  World w;
  const int tab = w.CreateWindow("file:///probe1.html");
  Check(tab >= (1 << 20), "AFTER_CREATED names the tab by cmux's minted id");
  Check(client.State(tab) == "file:///probe1.html", "AFTER_CREATED fills the new tab's history");
  std::optional<std::string> state_at_load_start;
  std::optional<std::string> entries_at_load_start;
  w.on_event = [&](const Event& e) {
    if (e.kind != CMUX_SHIM_LOAD_START || e.browser != tab) return;
    state_at_load_start = client.State(tab);
    entries_at_load_start = client.Entries(tab);
  };
  client.load_url(tab, "file:///probe2.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(state_at_load_start == "file:///probe1.html|file:///probe2.html",
        "the history read at LOAD_START has the new entry, got " + state_at_load_start.value_or("nothing"));
  Check(entries_at_load_start == "entries file:///probe1.html|file:///probe2.html",
        "the Back/Forward entries read at LOAD_START have it too");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
}

// One navigation cmux starts reads the history (page state included) when
// the host runs load_url, before its ACK (its pending keys, task 016b), then
// at ADDRESS and LOAD_START only: TITLE, LOAD_END and LOADING_STATE read and
// push nothing.
void OneNavigationPushesTheHistoryThreeTimes() {
  World w;
  const int tab = w.CreateWindow("file:///a.html");
  shim.state_reads = shim.entries_reads = 0;
  shim.state_padding = 1000;  // page state
  w.mirrors.clear();
  client.load_url(tab, "file:///b.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(shim.state_reads == 3 && shim.entries_reads == 3,
        "the history is read at load_url's ACK, ADDRESS and LOAD_START, got " + std::to_string(shim.state_reads) +
            " and " + std::to_string(shim.entries_reads) + " reads");
  Check(w.MirrorCount(cmux_host::kOpTabNavigationState) == 3 && w.MirrorCount(cmux_host::kOpTabNavigationEntries) == 3,
        "and pushed three times each");
  const size_t bytes = w.MirrorBytes(cmux_host::kOpTabNavigationState);
  Check(bytes < 3 * 1200, "history bytes per navigation: " + std::to_string(bytes));
  std::printf("chromium-host-mirror: one navigation pushes %zu bytes of history with 1000 bytes of page state\n", bytes);
  shim.state_reads = shim.entries_reads = 0;
  Emit(CMUX_SHIM_TITLE, 3, 0, 0, 0, "a title the page animates");
  Emit(CMUX_SHIM_LOADING_STATE, 3, 0, 0);
  Emit(CMUX_SHIM_LOAD_END, 3, 0, 200);
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(shim.state_reads == 0 && shim.entries_reads == 0, "TITLE, LOADING_STATE and LOAD_END read no history");
  // A same-document navigation (pushState, a fragment) commits with ADDRESS alone.
  shim.history[3].push_back("file:///b.html#c");
  Emit(CMUX_SHIM_ADDRESS, 3, 0, 0, 0, "file:///b.html#c");
  w.PumpUntilEvent(CMUX_SHIM_ADDRESS);
  Check(client.State(tab).value_or("").find("file:///b.html#c") != std::string::npos,
        "a same-document commit refreshes the history at ADDRESS");
}

// A history over the frame bound goes out as a forget: a read finds no
// value, never the history it replaced. The next one that fits is pushed.
void AHistoryOverTheFrameBoundIsForgotten() {
  World w;
  const int tab = w.CreateWindow("file:///a.html");
  Check(client.State(tab) == "file:///a.html", "a small history is cached");
  for (size_t padding : {size_t{65530}, size_t{70000}}) {  // over the frame's 64 KiB, over a field's
    shim.state_padding = padding;
    std::optional<std::string> at_load_start = "unread";
    w.on_event = [&](const Event& e) {
      if (e.kind == CMUX_SHIM_LOAD_START) at_load_start = client.State(tab);
    };
    client.load_url(tab, "file:///big.html");
    w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
    Check(!at_load_start, "a history of " + std::to_string(padding) + " bytes is no value, got " +
                              (at_load_start ? at_load_start->substr(0, 40) : std::string()));
  }
  Check(w.delegate.bad.empty() && ended == -1, "an oversized value ends neither side");
  shim.state_padding = 0;
  w.on_event = nullptr;
  client.load_url(tab, "file:///small.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(client.State(tab).value_or("").find("file:///small.html") != std::string::npos,
        "the next history that fits is cached again");
}

// The window id comes from the event where the event carries it.
void WindowIdFromTheEvent() {
  World w;
  shim.window_of[7] = 99;  // what the fork would say: the event's value wins
  ++shim.live;
  shim.history[7] = {"file:///7.html"};
  shim.window_id_reads = 0;
  Emit(CMUX_SHIM_AFTER_CREATED, 7, 0, 11);
  w.PumpUntilEvent(CMUX_SHIM_AFTER_CREATED);
  Check(client.window_id(7) == 11, "AFTER_CREATED's window");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabMoved, 12);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(client.window_id(7) == 12, "TAB_EVENT moved's window");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabInserted, 13);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(client.window_id(7) == 13, "TAB_EVENT inserted's window");
  Check(shim.window_id_reads == 0, "no shim read when the event carries the window");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabActivated, 13);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(shim.window_id_reads == 0 && client.window_id(7) == 13, "activation moves no tab");
  Emit(CMUX_SHIM_TAB_EVENT, 7, kTabRemoved, 13);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(shim.window_id_reads == 1 && client.window_id(7) == 99,
        "TAB_EVENT removed reads the tab's window from the fork");
}

// The counts: the remaining windows from the event, the rest from the shim.
void Counts() {
  World w;
  Check(client.navigation_restore_supported() == 1, "the fork capability came before the hello");
  Check(client.host_has_export("cmux_shim_tab_set_frozen") == 1 &&
            client.host_has_export("cmux_shim_tab_send_click") == 0,
        "the hello lists the optional exports the host's shim has");
  shim.windows = 3;
  w.CreateWindow("file:///a.html");
  Check(client.window_count() == 3 && client.live_browser_count() == 1,
        "AFTER_CREATED refreshes the window and browser counts");
  shim.window_count_reads = 0;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabWindowDestroyed, kWindow, 2);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(client.window_count() == 2 && shim.window_count_reads == 0,
        "window destroyed: the remaining count from the event, not the fork's (it still counts that window)");
  shim.foreign = 1;
  shim.windows = 4;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kForeignBrowserBlocked, 0, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(client.foreign_browser_count() == 1 && client.window_count() == 4,
        "a blocked foreign Browser refreshes the foreign and window counts");
  shim.windows = 5;
  Emit(CMUX_SHIM_TAB_EVENT, 0, kPopupWindowCreated, 0, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(client.window_count() == 5, "a popup window refreshes the window count");
}

// BEFORE_CLOSE forgets the tab's keys; later events push none for it.
void CloseForgets() {
  World w;
  const int tab = w.CreateWindow("file:///a.html");
  Check(client.State(tab) == "file:///a.html" && client.window_id(tab) == kWindow, "open tab cached");
  --shim.live;
  shim.windows = 1;
  int live_at_close = -1;
  w.on_event = [&](const Event& e) {
    if (e.kind == CMUX_SHIM_BEFORE_CLOSE) live_at_close = client.live_browser_count();
  };
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  w.PumpUntilEvent(CMUX_SHIM_BEFORE_CLOSE);
  Check(live_at_close == 0, "the counts are fresh in BEFORE_CLOSE's callback");
  Check(!client.State(tab) && !client.Entries(tab) && client.window_id(tab) == 0, "the cache forgot the tab");
  shim.state_reads = 0;
  Emit(CMUX_SHIM_ADDRESS, 3, 0);
  Emit(CMUX_SHIM_ADDRESS, 8, 0);  // a browser cmux has no tab for (DevTools)
  w.PumpUntilEvent(CMUX_SHIM_ADDRESS);
  Check(shim.state_reads == 0 && !client.State(3) && !client.State(8), "a closed tab, or no tab, gets no keys");
}

std::string Text(const std::set<int>& tabs) {
  std::string out;
  for (int tab : tabs) out += (out.empty() ? "" : ",") + std::to_string(tab);
  return out;
}

// Task 017: a tab cmux never asked about has its side panel, toolbar
// actions, extensions, shortcuts and omnibox keywords cached, and a read in
// LOAD_END's callback has the page's new badge.
void SitePanelAndExtensionsWithNoWatch() {
  World w;
  shim.side_panel[3] = "{\"visible\":false}";
  shim.ext_actions[3] = "[{\"id\":\"a\"}]";
  shim.ext_list[3] = "[\"a\"]";
  shim.ext_commands[3] = "[\"cmd\"]";
  shim.omnibox_keywords[3] = "[\"kw\"]";
  const int tab = w.CreateWindow("file:///a.html");
  const int px = cmux_host::kExtActionIconPixels;
  Check(client.Take(client.side_panel_state(tab)) == "{\"visible\":false}", "AFTER_CREATED pushes the side panel");
  Check(client.Take(client.ext_actions(tab, px)) == "[{\"id\":\"a\"}]", "and the toolbar actions at iconPixels");
  Check(!client.Take(client.ext_actions(tab, px + 1)), "at no other size");
  Check(client.Take(client.ext_list(tab)) == "[\"a\"]" && client.Take(client.ext_commands(tab)) == "[\"cmd\"]" &&
            client.Take(client.omnibox_keywords(tab)) == "[\"kw\"]",
        "and the extensions, shortcuts and omnibox keywords");
  bool sizes = !shim.icon_px.empty();
  for (int size : shim.icon_px) sizes = sizes && size == px;
  Check(sizes, "every ext_actions read is at CEFExtensionAction.iconPixels");
  shim.ext_actions[3] = "[{\"id\":\"a\",\"badge\":\"3\"}]";
  std::optional<std::string> at_load_end;
  w.on_event = [&](const Event& e) {
    if (e.kind == CMUX_SHIM_LOAD_END && e.browser == tab) at_load_end = client.Take(client.ext_actions(tab, px));
  };
  client.load_url(tab, "file:///b.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(at_load_end == "[{\"id\":\"a\",\"badge\":\"3\"}]",
        "a read in LOAD_END's callback has the page's badge, got " + at_load_end.value_or("nothing"));
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  w.PumpUntilEvent(CMUX_SHIM_BEFORE_CLOSE);
  Check(!client.Take(client.side_panel_state(tab)) && !client.Take(client.ext_actions(tab, px)) &&
            !client.Take(client.ext_list(tab)),
        "BEFORE_CLOSE forgets them");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
}

// The renderer client ids cmux maps to the host's helpers (task 225): one count and what fits the
// reader's buffer, the ids or nothing.
std::pair<int, std::vector<int>> RendererClients(int tab, int capacity) {
  std::vector<int> out(static_cast<size_t>(capacity), -1);
  const int count = client.renderer_client_ids(tab, out.data(), capacity);
  out.resize(static_cast<size_t>(std::clamp(count, 0, capacity)));
  return {count, out};
}

// Task 225: a tab's renderer client ids are in cmux's cache with no watch and no reply. AFTER_CREATED
// pushes them; a navigation that swaps the renderer has the new ones in the ADDRESS callback; an iframe
// renderer that comes or goes after the load has them in FRAME_RENDERERS' callback; a renderer's end
// refreshes them before RENDER_TERMINATED; BEFORE_CLOSE forgets them.
void RendererClientIDsWithNoWatch() {
  World w;
  shim.renderers[3] = {7};
  const int tab = w.CreateWindow("file:///a.html");
  Check(RendererClients(tab, 32).second == std::vector<int>{7}, "AFTER_CREATED pushes the tab's renderer");
  shim.renderers[3] = {9, 11};  // a cross-site navigation, and an out-of-process iframe
  std::vector<int> at_address;
  w.on_event = [&](const Event& e) {
    if (e.kind == CMUX_SHIM_ADDRESS && e.browser == tab) at_address = RendererClients(tab, 32).second;
  };
  client.load_url(tab, "file:///b.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(at_address == std::vector<int>({9, 11}), "a read in ADDRESS's callback has the new renderers");
  const auto [count, first] = RendererClients(tab, 1);
  Check(count == 2 && first == std::vector<int>{9}, "a smaller buffer gets what fits and the count");
  // An out-of-process iframe a script adds after LOAD_END, and its renderer's end: no main-frame event, the
  // shim's FRAME_RENDERERS refreshes them before its callback.
  shim.renderers[3] = {9, 11, 13};
  std::vector<int> at_frames;
  w.on_event = [&](const Event& e) {
    if (e.kind == CMUX_SHIM_FRAME_RENDERERS && e.browser == tab) at_frames = RendererClients(tab, 32).second;
  };
  Emit(CMUX_SHIM_FRAME_RENDERERS, 3, 0);
  w.PumpUntilEvent(CMUX_SHIM_FRAME_RENDERERS);
  Check(at_frames == std::vector<int>({9, 11, 13}), "an iframe renderer added after LOAD_END reaches the cache");
  shim.renderers[3] = {9, 11};
  Emit(CMUX_SHIM_FRAME_RENDERERS, 3, 0);
  w.PumpUntilEvent(CMUX_SHIM_FRAME_RENDERERS);
  Check(at_frames == std::vector<int>({9, 11}), "an iframe renderer's end leaves it");
  shim.renderers[3] = {};
  std::optional<int> at_terminated;
  w.on_event = [&](const Event& e) {
    if (e.kind == CMUX_SHIM_RENDER_TERMINATED) at_terminated = RendererClients(tab, 32).first;
  };
  Emit(CMUX_SHIM_RENDER_TERMINATED, 3, 1, 2, 9);
  w.PumpUntilEvent(CMUX_SHIM_RENDER_TERMINATED);
  Check(at_terminated == 0, "the renderer's end refreshes them before RENDER_TERMINATED's callback");
  shim.renderers[3] = {5};
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  w.PumpUntilEvent(CMUX_SHIM_BEFORE_CLOSE);
  Check(RendererClients(tab, 32).first == 0, "BEFORE_CLOSE forgets them");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
}

// Which tabs each refresh row of task 017's mirrors names. Every such row of
// the generated kMirrorRefreshes must be listed: a row added to the ops JSON
// fails here until its scope is written down.
enum class Names { kTab, kWindow, kProfile };
struct ScopeRow {
  uint16_t op;
  int kind;
  int request;  // -1: any
  Names names;
};
const ScopeRow kScopes[] = {
    {cmux_host::kOpExtActions, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {cmux_host::kOpExtActions, CMUX_SHIM_TAB_EVENT, kTabActionsChanged, Names::kWindow},
    {cmux_host::kOpExtActions, CMUX_SHIM_ADDRESS, -1, Names::kTab},
    {cmux_host::kOpExtActions, CMUX_SHIM_LOAD_END, -1, Names::kTab},
    {cmux_host::kOpExtActions, CMUX_SHIM_TAB_EVENT, kTabInserted, Names::kTab},
    {cmux_host::kOpExtActions, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {cmux_host::kOpExtList, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {cmux_host::kOpExtList, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {cmux_host::kOpExtList, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {cmux_host::kOpExtCommands, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {cmux_host::kOpExtCommands, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {cmux_host::kOpExtCommands, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {cmux_host::kOpSidePanelState, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {cmux_host::kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabInserted, Names::kTab},
    {cmux_host::kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabMoved, Names::kTab},
    {cmux_host::kOpSidePanelState, CMUX_SHIM_TAB_EVENT, kTabSidePanelChanged, Names::kWindow},
    {cmux_host::kOpSidePanelState, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
    {cmux_host::kOpOmniboxKeywords, CMUX_SHIM_AFTER_CREATED, -1, Names::kTab},
    {cmux_host::kOpOmniboxKeywords, CMUX_SHIM_TAB_EVENT, kTabExtensionsChanged, Names::kProfile},
    {cmux_host::kOpOmniboxKeywords, CMUX_SHIM_BEFORE_CLOSE, -1, Names::kTab},
};

// For each row: profile A has tabs 1 and 2 in window 11, tab 5 and a tab
// Chromium made (40) in window 13; profile B has tab 3 in window 12. The
// event comes from tab 1 in window 11, and the row's mirror must go out for
// exactly the tabs its scope names: never profile B's for A's change.
void RefreshRowsMatchTheirScope() {
  const std::set<int> ops = {cmux_host::kOpExtActions, cmux_host::kOpExtList, cmux_host::kOpExtCommands,
                             cmux_host::kOpSidePanelState, cmux_host::kOpOmniboxKeywords};
  std::set<std::tuple<int, int, int>> generated;
  for (const cmux_host::MirrorRefresh& row : cmux_host::kMirrorRefreshes) {
    if (ops.count(row.op)) generated.insert({row.op, row.kind, row.request});
  }
  std::set<std::tuple<int, int, int>> listed;
  for (const ScopeRow& row : kScopes) listed.insert({row.op, row.kind, row.request});
  Check(generated == listed, "the ops JSON's refresh rows of 017's mirrors are the rows this test scopes");

  for (const ScopeRow& row : kScopes) {
    World w;
    const int a1 = w.CreateWindow("file:///1.html", 11, "/profiles/a");
    const int chromium_a1 = shim.next_browser - 1;
    const int a2 = w.CreateWindow("file:///2.html", 11, "/profiles/a");
    w.CreateWindow("file:///3.html", 12, "/profiles/b");
    const int a5 = w.CreateWindow("file:///5.html", 13, "/profiles/a");
    // A tab Chromium made in window 13 takes the profile of the window's tabs.
    ++shim.live;
    shim.history[40] = {"file:///40.html"};
    Emit(CMUX_SHIM_AFTER_CREATED, 40, 0, 13);
    w.PumpUntilEvent(CMUX_SHIM_AFTER_CREATED);
    const std::string what = "mirror " + std::to_string(row.op) + " at event " + std::to_string(row.kind) + ":" +
                             std::to_string(row.request);
    if (row.kind == CMUX_SHIM_AFTER_CREATED) {
      w.KeysOf(row.op);
      const int tab = w.CreateWindow("file:///6.html", 11, "/profiles/a");
      Check(w.KeysOf(row.op) == std::set<int>{tab}, what + ": the new tab only");
      continue;
    }
    w.KeysOf(row.op);
    Emit(row.kind, chromium_a1, row.request < 0 ? 0 : row.request, 11);
    w.PumpUntilEvent(row.kind);
    std::set<int> want = {a1};
    if (row.names == Names::kWindow) want = {a1, a2};
    if (row.names == Names::kProfile) want = {a1, a2, a5, 40};
    const std::set<int> got = w.KeysOf(row.op);
    Check(got == want, what + ": got [" + Text(got) + "], want [" + Text(want) + "]");
  }
}

// The tab -> window and window -> profile records behind the scopes follow
// placement, moves, stale removals and window destruction.
void WindowsAndProfilesFollowTheTabs() {
  World w;
  const int panel = cmux_host::kOpSidePanelState;
  const int list = cmux_host::kOpExtList;
  const int a = w.CreateWindow("file:///a.html", 11, "/profiles/a");
  const int chromium_a = shim.next_browser - 1;
  const int b = w.CreateWindow("file:///b.html", 12, "/profiles/b");
  const int chromium_b = shim.next_browser - 1;
  // A popup Chromium places later: no window at AFTER_CREATED, then inserted into window 11.
  ++shim.live;
  shim.history[40] = {"file:///popup.html"};
  Emit(CMUX_SHIM_AFTER_CREATED, 40, 0, 0);
  Emit(CMUX_SHIM_TAB_EVENT, 40, kTabInserted, 11);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  w.KeysOf(panel);
  Emit(CMUX_SHIM_TAB_EVENT, chromium_a, kTabSidePanelChanged, 11, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(panel) == std::set<int>({a, 40}), "a placed popup joins its window's side panel refresh");
  Emit(CMUX_SHIM_TAB_EVENT, chromium_a, kTabExtensionsChanged, 11);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(list) == std::set<int>({a, 40}), "the popup takes its window's profile; profile B is not refreshed");

  Emit(CMUX_SHIM_TAB_EVENT, 40, kTabRemoved, 11);
  Emit(CMUX_SHIM_TAB_EVENT, 40, kTabInserted, 12);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  w.KeysOf(panel);
  Emit(CMUX_SHIM_TAB_EVENT, chromium_a, kTabSidePanelChanged, 11, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(panel) == std::set<int>({a}), "a moved tab leaves its old window's refresh");
  Emit(CMUX_SHIM_TAB_EVENT, chromium_b, kTabSidePanelChanged, 12, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(panel) == std::set<int>({b, 40}), "and joins its new window's");
  Emit(CMUX_SHIM_TAB_EVENT, 40, kTabRemoved, 11);  // late, from the window it left
  Emit(CMUX_SHIM_TAB_EVENT, chromium_b, kTabSidePanelChanged, 12, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(panel).count(40) == 1, "a stale removed keeps the current window");

  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabWindowDestroyed, 12, 1);
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabSidePanelChanged, 12, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  w.KeysOf(panel);
  Emit(CMUX_SHIM_TAB_EVENT, 0, kTabSidePanelChanged, 12, 1);
  w.PumpUntilEvent(CMUX_SHIM_TAB_EVENT);
  Check(w.KeysOf(panel).empty(), "a destroyed window names no tab");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
}

}  // namespace

int main() {
  client = LoadClient();
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ready = &OnReady;
  callbacks.ended = &OnEnded;
  client.configure(&callbacks);
  LoadStartReadsTheNewEntry();
  OneNavigationPushesTheHistoryThreeTimes();
  AHistoryOverTheFrameBoundIsForgotten();
  WindowIdFromTheEvent();
  Counts();
  CloseForgets();
  SitePanelAndExtensionsWithNoWatch();
  RendererClientIDsWithNoWatch();
  RefreshRowsMatchTheirScope();
  WindowsAndProfilesFollowTheTabs();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-mirror tests: ok");
  return EXIT_SUCCESS;
}
