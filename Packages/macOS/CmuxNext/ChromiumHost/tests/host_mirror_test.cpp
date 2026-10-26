// Checks the Chromium Host's navigation, window and count mirrors
// (src/host_mirror.mm, task p01-process-016) end to end: the real dispatcher
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
//   - event-carried windows and counts; BEFORE_CLOSE forgets the tab.
// Built and run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>

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
#include <string>
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
constexpr int kTabInserted = 0, kTabActivated = 1, kTabMoved = 2, kTabRemoved = 3, kTabWindowDestroyed = 6,
              kForeignBrowserBlocked = 9, kPopupWindowCreated = 10;
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
  int next_browser = 3;
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
  shim.window_of[browser] = kWindow;
  shim.history[browser] = {url ? url : ""};
  Emit(CMUX_SHIM_AFTER_CREATED, browser, request, kWindow);  // OnAfterCreated inside the call
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
};

struct Event {
  int kind, browser, request;
};

// One host and its attached remote shim.
struct World {
  Delegate delegate;
  Views views;
  std::unique_ptr<Channel> channel;
  // The host's MIRROR frames: op and body bytes.
  std::vector<std::pair<int, size_t>> mirrors;
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
    mirrors.emplace_back(static_cast<int>(m.fields.empty() ? 0 : m.fields[0].integer), bytes);
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

  // A window cmux creates through the remote shim; returns cmux's (minted) id.
  int CreateWindow(const char* url) {
    Check(client.create_window(42, nullptr, 800, 600, url, nullptr) == 1, "create_window is sent");
    PumpUntilEvent(CMUX_SHIM_AFTER_CREATED);
    return events.back().browser;
  }

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

// One navigation reads the history (page state included) at ADDRESS and
// LOAD_START only: TITLE, LOAD_END and LOADING_STATE read and push nothing.
void OneNavigationPushesTheHistoryTwice() {
  World w;
  const int tab = w.CreateWindow("file:///a.html");
  shim.state_reads = shim.entries_reads = 0;
  shim.state_padding = 1000;  // page state
  w.mirrors.clear();
  client.load_url(tab, "file:///b.html");
  w.PumpUntilEvent(CMUX_SHIM_LOAD_END);
  Check(shim.state_reads == 2 && shim.entries_reads == 2,
        "the history is read at ADDRESS and LOAD_START, got " + std::to_string(shim.state_reads) + " and " +
            std::to_string(shim.entries_reads) + " reads");
  Check(w.MirrorCount(cmux_host::kOpTabNavigationState) == 2 && w.MirrorCount(cmux_host::kOpTabNavigationEntries) == 2,
        "and pushed twice each");
  const size_t bytes = w.MirrorBytes(cmux_host::kOpTabNavigationState);
  Check(bytes < 2 * 1200, "history bytes per navigation: " + std::to_string(bytes));
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

}  // namespace

int main() {
  client = LoadClient();
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ready = &OnReady;
  callbacks.ended = &OnEnded;
  client.configure(&callbacks);
  LoadStartReadsTheNewEntry();
  OneNavigationPushesTheHistoryTwice();
  AHistoryOverTheFrameBoundIsForgotten();
  WindowIdFromTheEvent();
  Counts();
  CloseForgets();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-mirror tests: ok");
  return EXIT_SUCCESS;
}
