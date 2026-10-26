// Checks the Chromium Host's dispatcher (src/host_dispatch.mm) against a
// recording fake of the shim and fixtures/host_dispatch_subset.inc: the
// hello and attach mirrors come first; preinit ops run before
// cmux_shim_initialize and everything else after it, in cmux's order; a
// MIRROR goes out before the EVENT that refreshes it, and both before the
// ack of the op that caused them; client-minted ids map to Chromium's both
// ways; Chromium focuses a page only inside cmux's set_focus; a bad message
// ends the host. Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"

namespace {

using cmux_host::HostContext;
using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::tlv::Reader;
using cmux_host::tlv::Writer;

constexpr uint16_t kOpForkApiVersion = 3, kOpSetNewTabPageUrl = 23, kOpInitialize = 26, kOpCreateWindow = 28,
                   kOpTabAdd = 29, kOpLoadUrl = 35, kOpSetFocus = 40, kOpDevtoolsCall = 51,
                   kOpTabNavigationState = 65, kOpShutdown = 99;
constexpr uint16_t kOpEvent = 0x8001, kOpMirror = 0x8003, kOpAck = 0x8004;
constexpr int32_t kMinted = 1 << 20;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The fake shim's record and knobs.
struct Shim {
  std::vector<std::string> calls;
  HostContext* host = nullptr;
  cmux_shim_focus_request_fn focus = nullptr;
  cmux_shim_window_request_fn window = nullptr;
  int live = 0;
  int devtools_result = 77;
  int focus_answer = -1;  // what the focus handler said inside set_focus
} shim;

void Emit(int kind, int browser, int request, const char* s1 = "") {
  HostContext::OnShimEvent(shim.host, kind, browser, request, 0, 0, s1, "");
}

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn handler) { shim.focus = handler; }
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler) { shim.window = handler; }
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
void cmux_shim_set_new_tab_page_url(const char* url) { shim.calls.push_back(std::string("ntp ") + url); }
int cmux_shim_create_window(int request, void* parent_view, int, int, const char* url, const char*) {
  shim.calls.push_back("create " + std::to_string(request) + " " + url + (parent_view ? " view" : " noview"));
  ++shim.live;
  Emit(CMUX_SHIM_AFTER_CREATED, 3, request);  // OnAfterCreated inside the call
  return 1;
}
int cmux_shim_tab_add(int window_browser_id, const char*, int, int) {
  shim.calls.push_back("tab_add " + std::to_string(window_browser_id));
  ++shim.live;
  Emit(CMUX_SHIM_AFTER_CREATED, 4, 0);
  return 4;
}
void cmux_shim_load_url(int browser_id, const char* url) {
  shim.calls.push_back("load " + std::to_string(browser_id) + " " + url);
}
void cmux_shim_set_focus(int browser_id, int) {
  shim.calls.push_back("focus " + std::to_string(browser_id));
  shim.focus_answer = shim.focus ? shim.focus(shim.host, browser_id, 1) : -1;
}
int cmux_shim_devtools_call(int browser_id, const char* method, const char*) {
  shim.calls.push_back("devtools " + std::to_string(browser_id) + " " + method);
  return shim.devtools_result;
}
void cmux_shim_shutdown(void) { shim.calls.push_back("shutdown"); }
char* cmux_shim_tab_navigation_state(int browser_id) {
  shim.calls.push_back("nav_state " + std::to_string(browser_id));
  return strdup(("state of " + std::to_string(browser_id)).c_str());
}
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return shim.live; }
// The other mirrors of the fixture (host_mirror_test.cpp checks their values).
char* cmux_shim_tab_navigation_entries(int) { return nullptr; }
int cmux_shim_tab_window_id(int) { return 0; }
int cmux_shim_navigation_restore_supported(void) { return 1; }
int cmux_shim_foreign_browser_count(void) { return 0; }
int cmux_shim_window_count(void) { return 0; }
}

namespace {

struct Delegate : cmux_host::HostDelegate {
  std::vector<std::string> calls;
  std::vector<std::string> switches;
  void Initialize(cmux_host::InitializeRequest request) override {
    calls.push_back("initialize " + request.root_cache_path);
    switches = request.switches;
  }
  void Quit() override { calls.push_back("quit"); }
  void BrowserClosed() override { calls.push_back("closed"); }
  void BadMessage(const std::string& what) override { calls.push_back("bad " + what); }
};

struct Views : cmux_host::PageViews {
  std::vector<std::string> calls;
  int view = 0;
  void* Open(uint64_t token) override {
    calls.push_back("open " + std::to_string(token));
    return &view;
  }
  void Close(uint64_t token) override { calls.push_back("close " + std::to_string(token)); }
};

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

// "event <kind> <browser> <request>", "mirror <op> [key]", "ack <token>".
std::string Describe(const Message& m) {
  Reader r(m.fields);
  if (m.op == kOpEvent) {
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    return "event " + std::to_string(kind) + " " + std::to_string(browser) + " " + std::to_string(request);
  }
  if (m.op == kOpMirror) {
    const int op = r.I32(), key_count = r.I32();
    std::string text = "mirror " + std::to_string(op);
    for (int i = 0; i < key_count; ++i) text += " " + std::to_string(r.I32());
    return text;
  }
  if (m.op == kOpAck) return "ack " + std::to_string(m.token);
  return "op " + std::to_string(m.op);
}

struct Fixture {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views};
  Fixture() {
    shim = Shim();
    shim.host = &host;
  }
  std::vector<std::string> Sent() {
    std::vector<std::string> out;
    for (const Message& m : sent) out.push_back(Describe(m));
    sent.clear();
    return out;
  }
  void Start() {
    host.Attach(30, 1234);
    Writer init;
    init.Str("/fw");
    init.Str("/app");
    init.Str("/helper");
    init.Str("/root");
    init.Str(nullptr);
    init.I32(0);
    init.Str("en-US");
    init.Str(nullptr);
    const char* switches[] = {"--a"};
    init.StrList(switches, 1);
    host.OnMessages({Op(kOpInitialize, 1, init)});
    host.Resume();
    Sent();
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

void HelloFirst() {
  Fixture f;
  f.host.Attach(30, 1234);
  Expect(f.Sent(), {"mirror 3", "mirror 67", "event 0 0 0"}, "attach-only mirrors, then the hello");
  Check(f.delegate.calls.empty(), "no initialize before INITIALIZE");
}

void PreinitBeforeInitialize() {
  Fixture f;
  f.host.Attach(30, 1234);
  f.Sent();
  Writer ntp;
  ntp.Str("cmux-page://home/");
  Writer init;
  init.Str("/fw");
  init.Str("/app");
  init.Str("/helper");
  init.Str("/root");
  init.Str(nullptr);
  init.I32(0);
  init.Str(nullptr);
  init.Str(nullptr);
  const char* switches[] = {"--a", "--b=c"};
  init.StrList(switches, 2);
  Writer load;
  load.I32(5);
  load.Str("https://a/");
  Writer watch;
  watch.I32(5);
  f.host.OnMessages({Op(kOpSetNewTabPageUrl, 10, ntp), Op(kOpTabNavigationState, 0, watch), Op(kOpInitialize, 11, init),
                     Op(kOpLoadUrl, 12, load)});
  Expect(shim.calls, {"ntp cmux-page://home/"}, "only the preinit op runs before initialize");
  Expect(f.delegate.calls, {"initialize /root"}, "initialize after the preinit op");
  Check(f.delegate.switches == std::vector<std::string>({"--a", "--b=c"}), "the switches arrive");
  Expect(f.Sent(), {"ack 10"}, "the preinit op is acked");
  f.host.OnMessages({Op(kOpLoadUrl, 13, load)});  // read while initialize runs
  Check(shim.calls.size() == 1, "nothing runs while initialize runs");
  f.host.Resume();
  Expect(shim.calls, {"ntp cmux-page://home/", "nav_state 5", "load 5 https://a/", "load 5 https://a/"},
         "after initialize, the waiting messages in cmux's order");
  Expect(f.Sent(), {"ack 11", "mirror 91", "mirror 97", "mirror 98", "mirror 65 5", "ack 12", "ack 13"},
         "initialize acked, then the counts that refresh on attach too, then the rest");
  Check(shim.focus != nullptr && shim.window != nullptr, "the host's policies are installed after initialize");
}

void MintedWindow() {
  Fixture f;
  f.Start();
  Writer create;
  create.I32(kMinted);
  create.I32(42);
  create.ViewToken(9);
  create.I32(800);
  create.I32(600);
  create.Str("https://b/");
  create.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 20, create)});
  Expect(shim.calls, {"create 42 https://b/ view", "nav_state 3"},
         "create_window with the host's view; the new tab's navigation state is read at AFTER_CREATED");
  Expect(f.views.calls, {"open 9"}, "the page view token opens a view");
  const std::string minted = std::to_string(kMinted);
  Expect(f.Sent(),
         {"mirror 32 " + minted, "mirror 34 " + minted, "mirror 65 " + minted, "mirror 97", "mirror 98",
          "event 2 " + minted + " 42", "ack 20"},
         "AFTER_CREATED carries the minted id; its mirrors first, the ack last");

  Writer watch;
  watch.I32(kMinted);
  Writer load;
  load.I32(kMinted);
  load.Str("https://c/");
  f.host.OnMessages({Op(kOpTabNavigationState, 0, watch), Op(kOpLoadUrl, 21, load)});
  Expect(shim.calls, {"create 42 https://b/ view", "nav_state 3", "nav_state 3", "load 3 https://c/"},
         "the minted id reaches the shim as Chromium's");
  f.Sent();
  Emit(CMUX_SHIM_LOAD_START, 3, 0, "https://c/");
  Expect(f.Sent(), {"mirror 32 " + minted, "mirror 65 " + minted, "event 8 " + minted + " 0"},
         "the tab's mirrors go out before the event that refreshes them");

  shim.live = 0;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  Expect(f.Sent(),
         {"mirror 32 " + minted, "mirror 34 " + minted, "mirror 65 " + minted, "mirror 97", "mirror 98",
          "event 3 " + minted + " 0"},
         "BEFORE_CLOSE: last mirrors, then the event");
  Expect(f.views.calls, {"open 9", "close 9"}, "the browser's page view closes with it");
  Expect(f.delegate.calls, {"initialize /root", "closed"}, "the delegate hears of the close");
  Emit(CMUX_SHIM_TITLE, 3, 0);
  Expect(f.Sent(), {"event 5 3 0"}, "a closed browser's id is no longer mapped, and its watch is gone");
}

void MintedTab() {
  Fixture f;
  f.Start();
  Writer add;
  add.I32(kMinted + 1);
  add.I32(3);
  add.Str("https://d/");
  add.I32(-1);
  add.I32(1);
  f.host.OnMessages({Op(kOpTabAdd, 30, add)});
  const std::string minted = std::to_string(kMinted + 1);
  Expect(f.Sent(),
         {"mirror 32 " + minted, "mirror 34 " + minted, "mirror 65 " + minted, "mirror 97", "mirror 98",
          "event 2 " + minted + " 0", "ack 30"},
         "an AFTER_CREATED inside tab_add already carries the minted id");
}

void DevTools() {
  Fixture f;
  f.Start();
  Writer call;
  call.I32(500);
  call.I32(3);
  call.Str("Page.reload");
  call.Str(nullptr);
  f.host.OnMessages({Op(kOpDevtoolsCall, 40, call)});
  f.Sent();
  HostContext::OnShimEvent(&f.host, CMUX_SHIM_DEVTOOLS_RESULT, 3, 77, 1, 0, "{}", "");
  Expect(f.Sent(), {"event 13 3 500"}, "DEVTOOLS_RESULT answers the minted message id");
  shim.devtools_result = 0;
  call = Writer();
  call.I32(501);
  call.I32(3);
  call.Str("Bad.method");
  call.Str(nullptr);
  f.host.OnMessages({Op(kOpDevtoolsCall, 41, call)});
  Expect(f.Sent(), {"event 13 3 501", "ack 41"}, "a refused call is a DEVTOOLS_RESULT for its minted id, before the ack");
}

void FocusOnlyFromCmux() {
  Fixture f;
  f.Start();
  Check(shim.focus && shim.focus(&f.host, 3, 0) == 0, "Chromium's own focus request is refused");
  Writer focus;
  focus.I32(3);
  focus.I32(1);
  f.host.OnMessages({Op(kOpSetFocus, 50, focus)});
  Check(shim.focus_answer == 1, "the request inside cmux's set_focus is granted");
  Check(shim.window && shim.window(&f.host, 2, 0, 3, 0, 0, 0, 0, 0, 1, "https://p/", "") == 3,
        "a popup opens as a tab in the opener's window");
  Check(shim.window(&f.host, 3, 0, 3, 0, 0, 0, 0, 0, 1, "https://p/", "") == 0, "an incognito window opens nothing");
}

void Shutdown() {
  Fixture f;
  f.Start();
  f.host.OnMessages({Op(kOpShutdown, 60, Writer())});
  Expect(f.Sent(), {"ack 60"}, "shutdown is acked");
  Expect(f.delegate.calls, {"initialize /root", "quit"}, "shutdown quits the loop");
  Check(shim.calls.empty(), "CefShutdown never runs inside a task");
}

void BadMessages() {
  {
    Fixture f;
    f.Start();
    Writer wrong;
    wrong.Str("not a browser id");
    wrong.Str("https://e/");
    Writer load;
    load.I32(5);
    load.Str("https://f/");
    f.host.OnMessages({Op(kOpLoadUrl, 70, wrong), Op(kOpLoadUrl, 71, load)});
    Check(f.delegate.calls.size() == 2 && f.delegate.calls[1].rfind("bad ", 0) == 0, "a malformed op is bad");
    Check(shim.calls.empty(), "nothing runs after a bad message");
  }
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({Op(999, 1, Writer())});
    Check(f.delegate.calls.back().rfind("bad ", 0) == 0, "an unknown op is bad");
  }
  {
    Fixture f;
    f.Start();
    Message reply = Op(kOpLoadUrl, 1, Writer());
    reply.reply = true;
    f.host.OnMessages({reply});
    Check(f.delegate.calls.back() == "bad a reply frame from cmux", "a reply frame from cmux is bad");
  }
  {
    Fixture f;
    f.Start();
    Writer init;
    init.Str("/fw");
    f.host.OnMessages({Op(kOpInitialize, 2, init)});
    Check(f.delegate.calls.back() == "bad a second initialize", "a second initialize is bad");
  }
  {
    Fixture f;
    f.Start();
    Writer key;
    key.Str("x");
    f.host.OnMessages({Op(kOpForkApiVersion, 0, key)});
    Check(f.delegate.calls.back().rfind("bad a malformed mirror key", 0) == 0, "a malformed mirror key is bad");
  }
}

void WipeZeroes() {
  std::vector<std::string> secrets = {"hunter2", ""};
  cmux_host::Wipe(secrets);
  Check(secrets[0].empty() && secrets[1].empty(), "Wipe clears every secret");
}

}  // namespace

int main() {
  HelloFirst();
  PreinitBeforeInitialize();
  MintedWindow();
  MintedTab();
  DevTools();
  FocusOnlyFromCmux();
  Shutdown();
  BadMessages();
  WipeZeroes();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-dispatch tests: ok");
  return EXIT_SUCCESS;
}
