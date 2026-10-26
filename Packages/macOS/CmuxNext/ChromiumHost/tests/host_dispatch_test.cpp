// Checks the Chromium Host's dispatcher (src/host_dispatch.mm) against a
// recording fake of the shim and the generated cases
// (generated/host_dispatch.inc, written by gen-chromium-host-wire.py): cmux's
// HELLO of this wire comes first; the attach mirrors, then the host's HELLO
// with the optional exports its shim has; preinit ops run before
// cmux_shim_initialize and everything else after it, in cmux's order; a
// MIRROR goes out before the EVENT that refreshes it, and both before the
// ack of the op that caused them; client-minted ids map to Chromium's both
// ways; Chromium focuses a page only inside cmux's set_focus; a page's
// accessibility token comes back in its REPLY; a page window whose layers
// are hosted is detached; a page view moves only when its geometry changed
// (task 053); a bad message ends the host. Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "chromium_host_input_ring.h"
#include "cmux_cef_shim.h"
#include "host_dispatch.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;  // the generated op ids
using cmux_host::HostContext;
using cmux_host::control::Field;
using cmux_host::control::Message;
using Reader = cmux_host::control::TlvReader;
using Writer = cmux_host::control::TlvWriter;

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
  int focus_handler_sets = 0;  // set_focus_request_handler calls (nullptr counts)
  cmux_shim_window_request_fn window = nullptr;
  int live = 0;
  int devtools_result = 77;
  int focus_answer = -1;  // what the focus handler said inside set_focus
  bool create_at_once = true;  // create_window's AFTER_CREATED comes inside the call
  int create_result = 1;       // create_window's return (0: refused)
  bool refuse_detach = false;  // set_detached_hosting(1) answers 0 (a fork that cannot detach)
  // (browser, request): AFTER_CREATED events the next create_window emits inside the call, in order.
  std::vector<std::pair<int, int>> created_in_call;
} shim;

void Emit(int kind, int browser, int request, const char* s1 = "") {
  HostContext::OnShimEvent(shim.host, kind, browser, request, 0, 0, s1, "");
}

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn handler) {
  shim.focus = handler;
  ++shim.focus_handler_sets;
}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn handler) { shim.window = handler; }
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
void cmux_shim_set_new_tab_page_url(const char* url) { shim.calls.push_back(std::string("ntp ") + url); }
int cmux_shim_create_window(int request, void* parent_view, int, int, const char* url, const char*) {
  shim.calls.push_back("create " + std::to_string(request) + " " + url + (parent_view ? " view" : " noview"));
  if (!shim.create_result) return 0;
  ++shim.live;
  if (shim.create_at_once) Emit(CMUX_SHIM_AFTER_CREATED, 3, request);  // OnAfterCreated inside the call
  const std::vector<std::pair<int, int>> created = std::move(shim.created_in_call);
  shim.created_in_call.clear();
  for (const auto& [browser, created_request] : created) Emit(CMUX_SHIM_AFTER_CREATED, browser, created_request);
  return 1;
}
int TabSetFrozen(int browser_id, int frozen) {
  shim.calls.push_back("frozen " + std::to_string(browser_id) + " " + std::to_string(frozen));
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
// The fork's embedder-active focuses the page's views: CEF asks the focus
// handler inside the call (task 046).
int cmux_shim_browser_set_embedder_active(int browser_id, int active) {
  shim.calls.push_back("embedder_active " + std::to_string(browser_id) + " " + std::to_string(active));
  shim.focus_answer = shim.focus ? shim.focus(shim.host, browser_id, 1) : -1;
  return 1;
}
int cmux_shim_devtools_call(int browser_id, const char* method, const char*) {
  shim.calls.push_back("devtools " + std::to_string(browser_id) + " " + method);
  return shim.devtools_result;
}
void cmux_shim_devtools_set_placement(int browser_id, void* parent_view, int, int, int, int) {
  shim.calls.push_back("placement " + std::to_string(browser_id) + (parent_view ? " view" : " noview"));
}
// The fork's page accessibility call (task 049): takes the embedder's tokens, copies the page's
// token into `out` when it fits and returns its length; 0 for a browser it does not have.
int cmux_shim_browser_accessibility_token(int browser_id, int embedder_pid, const uint8_t* parent_token,
                                          int parent_token_length, const uint8_t* window_token,
                                          int window_token_length, uint8_t* out, int capacity) {
  shim.calls.push_back("ax " + std::to_string(browser_id) + " " + std::to_string(embedder_pid) + " " +
                       std::string(reinterpret_cast<const char*>(parent_token), parent_token_length) + " " +
                       std::string(reinterpret_cast<const char*>(window_token), window_token_length));
  if (browser_id != 3) return 0;
  static constexpr char kToken[] = "page-token";
  constexpr int kLength = sizeof kToken - 1;
  if (out && capacity >= kLength) std::memcpy(out, kToken, kLength);
  return kLength;
}
// The fork's layer hosting gives browser 3 a context and refuses every other browser.
unsigned int cmux_shim_browser_set_layer_hosting(int browser_id, int enabled) {
  shim.calls.push_back("layer_hosting " + std::to_string(browser_id) + " " + std::to_string(enabled));
  return enabled && browser_id == 3 ? 0xC0FFEEu : 0u;
}
int cmux_shim_browser_set_detached_hosting(int browser_id, int enabled) {
  shim.calls.push_back("detached " + std::to_string(browser_id) + " " + std::to_string(enabled));
  return enabled && shim.refuse_detach ? 0 : 1;
}
void cmux_shim_shutdown(void) { shim.calls.push_back("shutdown"); }
char* cmux_shim_tab_navigation_state(int browser_id) {
  shim.calls.push_back("nav_state " + std::to_string(browser_id));
  return strdup(("state of " + std::to_string(browser_id)).c_str());
}
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return shim.live; }
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
  void Place(uint64_t token, const cmux_host::PageGeometry& g) override {
    calls.push_back("place " + std::to_string(token) + " " + std::to_string(g.width) + "x" + std::to_string(g.height) +
                    " at " + std::to_string(g.screen_x) + "," + std::to_string(g.screen_y));
  }
};

// The host's shim has one optional export.
void* Resolve(const char* name) {
  return std::strcmp(name, "cmux_shim_tab_set_frozen") == 0 ? reinterpret_cast<void*>(&TabSetFrozen) : nullptr;
}

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

// cmux's first frame (remote_shim.mm Attach).
Message Hello(const char* wire = kWireID, const char* abi = kShimAbiID) {
  Writer w;
  w.Str(wire);
  w.Str(abi);
  return Op(control::kOpHello, 0, w);
}

// "event <kind> <browser> <request>", "mirror <op> [key]" ("forget <op> [key]"
// with no value), "hello [exports]", "ack <token>", "reply <token> <i32>".
std::string Describe(const Message& m) {
  Reader r(m.fields);
  if (m.op == kOpEvent) {
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    return "event " + std::to_string(kind) + " " + std::to_string(browser) + " " + std::to_string(request);
  }
  if (m.op == kOpMirror) {
    const int op = r.I32();
    std::vector<Field> key;
    const bool key_ok = control::DecodeFields(r.Bytes(), &key);
    const bool forget = r.AtEnd();
    std::vector<Field> value;
    if (!forget && !control::DecodeFields(r.Bytes(), &value)) return "malformed value";
    if (!key_ok || !r.ok() || !r.AtEnd()) return "malformed mirror";
    std::string text = (forget ? "forget " : "mirror ") + std::to_string(op);
    for (const Field& field : key) text += " " + std::to_string(field.integer);
    return text;
  }
  if (m.op == control::kOpHello) {
    const std::optional<std::string> wire = r.Str();
    std::string text = wire == std::optional<std::string>(kWireID) ? "hello" : "hello of another wire";
    for (const std::string& name : r.StrList()) text += " " + name;
    return r.ok() && r.AtEnd() ? text : "malformed hello";
  }
  if (m.op == kOpAck) return "ack " + std::to_string(m.token);
  if (m.op == kOpReply) return "reply " + std::to_string(m.token) + " " + std::to_string(r.I32());
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
                   delegate, views, &Resolve};
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
    host.Attach();
    host.OnMessages({Hello()});
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

// "<verb> <op>", then " <key>" when a key is given.
std::string Key(const std::string& verb, uint16_t op, const std::string& key = "") {
  return verb + " " + std::to_string(op) + (key.empty() ? "" : " " + key);
}

void Expect(const std::vector<std::string>& got, const std::vector<std::string>& want, const char* what) {
  Check(got == want, std::string(what) + ": got [" + Join(got) + "], want [" + Join(want) + "]");
}

void HelloFirst() {
  Fixture f;
  f.host.Attach();
  auto mirror = [](uint16_t op) { return "mirror " + std::to_string(op); };
  Expect(f.Sent(),
         {mirror(kOpForkApiVersion), mirror(kOpPlaceholderSupported), mirror(kOpNavigationRestoreSupported), mirror(kOpPasswordImportAvailable),
          mirror(kOpPasswordReplaceAvailable), mirror(kOpPasskeysAvailable), mirror(kOpPasswordCoreAvailable),
          mirror(kOpExtLoadLaterSupported), "hello cmux_shim_tab_set_frozen"},
         "attach-only mirrors, then the hello with the optional exports the shim has");
  Check(f.delegate.calls.empty(), "no initialize before INITIALIZE");
  f.host.OnMessages({Hello()});
  Check(f.delegate.calls.empty(), "cmux's hello of this wire is accepted");
}

void HelloOfAnotherWire() {
  {
    Fixture f;
    f.host.Attach();
    f.host.OnMessages({Hello("another wire")});
    Check(f.delegate.calls == std::vector<std::string>({"bad no hello of this wire first"}),
          "a hello of another generation of the op table is bad");
  }
  {
    Fixture f;
    f.host.Attach();
    f.host.OnMessages({Hello(kWireID, "another header")});
    Check(f.delegate.calls == std::vector<std::string>({"bad no hello of this wire first"}),
          "a hello of another shim header is bad");
  }
  {
    Fixture f;
    f.host.Attach();
    Writer ntp;
    ntp.Str("cmux-page://home/");
    f.host.OnMessages({Op(kOpSetNewTabPageUrl, 1, ntp)});
    Check(f.delegate.calls == std::vector<std::string>({"bad no hello of this wire first"}) && shim.calls.empty(),
          "an op before the hello is bad and does not run");
  }
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({Hello()});
    Check(f.delegate.calls.back() == "bad a second hello", "a second hello is bad");
  }
}

void OptionalExports() {
  Fixture f;
  f.Start();
  Writer frozen;
  frozen.I32(3);
  frozen.I32(1);
  f.host.OnMessages({Op(kOpTabSetFrozen, 80, frozen)});
  Expect(shim.calls, {"frozen 3 1"}, "an optional op calls the host shim's function");
  Expect(f.Sent(), {"reply 80 1"}, "and answers its result");
  Writer scheme;
  scheme.I32(3);
  scheme.I32(1);
  f.host.OnMessages({Op(kOpTabSetColorScheme, 81, scheme)});
  Expect(f.Sent(), {"ack 81"}, "an optional op the shim does not have runs nothing and is acked");
}

void PreinitBeforeInitialize() {
  Fixture f;
  f.host.Attach();
  f.host.OnMessages({Hello()});
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
  Expect(f.Sent(), {"ack 11", Key("mirror", kOpForeignBrowserCount), Key("mirror", kOpLiveBrowserCount),
                    Key("mirror", kOpWindowCount), Key("mirror", kOpTabNavigationState, "5"), "ack 12", "ack 13"},
         "initialize acked, then the counts that refresh on attach too, then the rest");
  Check(shim.focus_handler_sets > 0 && shim.focus == nullptr && shim.window != nullptr,
        "after initialize the host's window policy is installed and no focus handler (task p01-process-032)");
}

// What AFTER_CREATED (`verb` "mirror") or BEFORE_CLOSE ("forget") sends for
// tab `id`, in kMirrorRefreshes' order (the ops JSON's): the navigation
// entries, the window, the toolbar actions at cmux's icon size, the
// navigation state, the extensions, the shortcuts, the side panel and the
// omnibox keywords, then `rest`.
std::vector<std::string> TabKeys(const std::string& verb, const std::string& id, std::vector<std::string> rest) {
  const std::string px = std::to_string(cmux_host::kExtActionIconPixels);
  std::vector<std::string> out = {Key(verb, kOpTabNavigationEntries, id), Key(verb, kOpTabWindowId, id),
                                  Key(verb, kOpExtActions, id + " " + px), Key(verb, kOpTabNavigationState, id),
                                  Key(verb, kOpExtList, id), Key(verb, kOpExtCommands, id),
                                  Key(verb, kOpSidePanelState, id), Key(verb, kOpOmniboxKeywords, id)};
  out.insert(out.end(), rest.begin(), rest.end());
  return out;
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
         TabKeys("mirror", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount), "event 2 " + minted + " 42", "ack 20"}),
         "AFTER_CREATED carries the minted id; its mirrors first, the ack last");

  Writer watch;
  watch.I32(kMinted);
  Writer load;
  load.I32(kMinted);
  load.Str("https://c/");
  f.host.OnMessages({Op(kOpTabNavigationState, 0, watch), Op(kOpLoadUrl, 21, load)});
  Expect(shim.calls, {"create 42 https://b/ view", "nav_state 3", "nav_state 3", "load 3 https://c/", "nav_state 3"},
         "the minted id reaches the shim as Chromium's; load_url's pending keys are read again after the call");
  Expect(f.Sent(), {Key("mirror", kOpTabNavigationState, minted), Key("mirror", kOpTabNavigationEntries, minted),
                    Key("mirror", kOpTabNavigationState, minted), "ack 21"},
         "the watch's value, then load_url's pending keys pushed again before its ack (task 016b)");
  Emit(CMUX_SHIM_LOAD_START, 3, 0, "https://c/");
  Expect(f.Sent(), {Key("mirror", kOpTabNavigationEntries, minted), Key("mirror", kOpTabNavigationState, minted),
                    "event 8 " + minted + " 0"},
         "the tab's mirrors go out before the event that refreshes them");

  shim.live = 0;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  Expect(f.Sent(),
         TabKeys("forget", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount), "event 3 " + minted + " 0"}),
         "BEFORE_CLOSE: the tab's keys forgotten, the counts refreshed, then the event");
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
         TabKeys("mirror", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount), "event 2 " + minted + " 0", "ack 30"}),
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

// devtools_set_placement's view (task 024): the placement stands for every
// DevTools of the inspected browser, Chromium's own opens too (context menu
// Inspect), so a DevTools close keeps it and its view. The view closes with
// the inspected browser or a placement that replaces it.
void DevToolsPlacementView() {
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
  auto place = [&](uint32_t token, uint64_t view) {
    Writer w;
    w.I32(kMinted);
    w.ViewToken(view);
    w.I32(0);
    w.I32(0);
    w.I32(400);
    w.I32(300);
    f.host.OnMessages({Op(kOpDevtoolsSetPlacement, token, w)});
  };
  shim.calls.clear();
  place(21, 12);
  Expect(shim.calls, {"placement 3 view"}, "the placement reaches the shim for Chromium's browser, with the host's view");
  Expect(f.views.calls, {"open 9", "open 12"}, "the DevTools placement opens its own view");

  Emit(CMUX_SHIM_DEVTOOLS_CLOSED, 3, 0);
  Emit(CMUX_SHIM_DEVTOOLS_CLOSED, 3, 0);
  Expect(shim.calls, {"placement 3 view"}, "a closed DevTools leaves the placement standing for the next open");
  Expect(f.views.calls, {"open 9", "open 12"}, "a closed DevTools keeps its placement's view");

  place(22, 12);
  Expect(f.views.calls, {"open 9", "open 12", "open 12"}, "the same view placed again stays open");

  place(23, 0);
  Expect(shim.calls, {"placement 3 view", "placement 3 view", "placement 3 noview"},
         "a placement in a window of its own reaches the shim with no view");
  Expect(f.views.calls, {"open 9", "open 12", "open 12", "close 12"},
         "a placement in a window of its own closes the view it replaced");
  Emit(CMUX_SHIM_DEVTOOLS_CLOSED, 3, 0);
  Check(f.views.calls.size() == 4, "a DevTools close after it releases nothing");

  place(24, 13);
  place(25, 14);
  Expect(f.views.calls, {"open 9", "open 12", "open 12", "close 12", "open 13", "open 14", "close 13"},
         "a placement that names another view closes the one it replaced");

  shim.calls.clear();
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  Expect(f.views.calls,
         {"open 9", "open 12", "open 12", "close 12", "open 13", "open 14", "close 13", "close 14", "close 9"},
         "the inspected browser's close closes its DevTools view and its page view");
  Check(shim.calls.empty(), "the shim forgets a closed browser's placement itself");
}

// The host installs no focus handler (task p01-process-032): the shim grants a
// focus request only for a page cmux marked embedder-active
// (CEFShim/src/embedder_focus_policy.h). cmux installing its in-process
// handler over the wire changes nothing, and embedder-active reaches the shim.
void FocusIsTheShimsEmbedderActiveRule() {
  Fixture f;
  f.Start();
  Check(shim.focus == nullptr, "no focus handler after initialize");
  Writer install;
  install.I32(1);
  f.host.OnMessages({Op(kOpSetFocusRequestHandler, 50, install)});
  Check(shim.focus == nullptr, "cmux's focus handler is not installed in the host");
  shim.calls.clear();
  Writer active;
  active.I32(3);
  active.I32(1);
  f.host.OnMessages({Op(kOpBrowserSetEmbedderActive, 51, active)});
  Expect(shim.calls, {"embedder_active 3 1"}, "embedder-active reaches the shim, which owns the focus rule");
  Check(shim.focus_answer == -1, "no host handler is asked inside it");
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

// popup_window.bounds is keyed by the Chromium window, which TAB_EVENT 6, 10
// and 11 name in a; the reporting browser's id is another number.
void PopupBoundsByWindow() {
  Fixture f;
  f.Start();
  Writer watch;
  watch.I32(77);
  f.host.OnMessages({Op(kOpPopupWindowBounds, 0, watch)});
  const std::string bounds = "mirror " + std::to_string(kOpPopupWindowBounds) + " 77";
  Expect(f.Sent(), {bounds}, "the watch pushes the window's bounds");
  HostContext::OnShimEvent(&f.host, CMUX_SHIM_TAB_EVENT, 5, 11, 77, 0, "", "");
  Expect(f.Sent(), {bounds, "event 16 5 11"}, "bounds changed in window 77: its key, then the event");
  HostContext::OnShimEvent(&f.host, CMUX_SHIM_TAB_EVENT, 77, 11, 78, 0, "", "");
  Expect(f.Sent(), {"event 16 77 11"}, "another window's change leaves it, even from browser 77");
}

// cmux's page view and window tokens reach the fork for Chromium's browser, and the page's token
// comes back in the REPLY: its length, then the out buffer of the capacity cmux asked for (task 049;
// ChromiumHostAccessibilityToken in cmux reads it so).
void AccessibilityToken() {
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
  f.Sent();
  shim.calls.clear();
  struct Answer {
    int32_t length = -1;
    std::string buffer;
  };
  auto ask = [&f](int32_t browser, int32_t capacity, uint32_t token) {
    Writer w;
    w.I32(browser);
    w.I32(4242);
    w.Bytes("view", 4);
    w.Bytes("win", 3);
    w.I32(capacity);
    f.host.OnMessages({Op(kOpBrowserAccessibilityToken, token, w)});
    Answer answer;
    Check(f.sent.size() == 1 && f.sent[0].op == kOpReply && f.sent[0].token == token,
          "one REPLY under the request's token " + std::to_string(token));
    if (f.sent.size() != 1) return answer;
    Reader r(f.sent[0].fields);
    answer.length = r.I32();
    answer.buffer = r.Bytes();
    Check(r.ok() && r.AtEnd(), "the REPLY is the result, then the out buffer");
    f.sent.clear();
    return answer;
  };

  const Answer fits = ask(kMinted, 64, 50);
  Expect(shim.calls, {"ax 3 4242 view win"}, "the minted id reaches the fork as Chromium's, with cmux's pid and tokens");
  Check(fits.length == 10 && fits.buffer.size() == 64 && fits.buffer.compare(0, 10, "page-token") == 0,
        "the page's token's length, and the token at the start of the buffer cmux sized");

  const Answer short_buffer = ask(kMinted, 4, 51);
  Check(short_buffer.length == 10 && short_buffer.buffer == std::string(4, '\0'),
        "a token longer than the buffer: its length, nothing copied (cmux asks again at that length)");

  const Answer unknown = ask(77, 64, 52);
  Check(unknown.length == 0, "a browser the fork does not have: no token");
  Expect(f.delegate.calls, {"initialize /root"}, "no bad message");
}

// cmux shows a page it minted in the key's turn, so an assistive client can read it before
// Chromium created its browser: the request waits for the creation instead of reaching the fork
// under an id it does not know (task 049).
void AccessibilityTokenBeforeCreation() {
  Fixture f;
  f.Start();
  shim.create_at_once = false;
  Writer create;
  create.I32(kMinted + 5);
  create.I32(43);
  create.ViewToken(10);
  create.I32(800);
  create.I32(600);
  create.Str("https://b/");
  create.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 20, create)});
  f.Sent();
  shim.calls.clear();
  Writer w;
  w.I32(kMinted + 5);
  w.I32(4242);
  w.Bytes("view", 4);
  w.Bytes("win", 3);
  w.I32(64);
  f.host.OnMessages({Op(kOpBrowserAccessibilityToken, 60, w)});
  Check(shim.calls.empty() && f.sent.empty(), "before the creation: no fork call and no reply");

  Emit(CMUX_SHIM_AFTER_CREATED, 3, 43);
  Expect(shim.calls, {"nav_state 3", "ax 3 4242 view win"}, "the creation runs the held request on Chromium's id");
  std::vector<std::string> sent = f.Sent();
  const std::string minted = std::to_string(kMinted + 5);
  const auto event = std::find(sent.begin(), sent.end(), "event 2 " + minted + " 43");
  const auto reply = std::find(sent.begin(), sent.end(), "reply 60 10");
  Check(event != sent.end() && reply != sent.end() && event < reply,
        "the creation's event, then the page token's reply: [" + Join(sent) + "]");

  // A peer that floods one uncreated browser with requests breaks the wire's bounds.
  Writer again;
  again.I32(kMinted + 6);
  again.I32(44);
  again.ViewToken(11);
  again.I32(800);
  again.I32(600);
  again.Str("https://c/");
  again.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 21, again)});
  Writer flood;
  flood.I32(kMinted + 6);
  flood.I32(4242);
  flood.Bytes("view", 4);
  flood.Bytes("win", 3);
  flood.I32(64);
  for (uint32_t token = 70; token < 87; ++token) f.host.OnMessages({Op(kOpBrowserAccessibilityToken, token, flood)});
  Check(f.delegate.calls.back() == "bad too many accessibility requests waiting for a browser's creation",
        "the 17th held request is a bad message");
}

// Chromium can create a browser cmux minted inside another op's call. Its held page accessibility
// request runs after that op's ack, as an op of its own: the op's mirrors and events still come
// before its ack, and the held request's reply after it (task 049).
void AccessibilityTokenCreatedInsideAnotherOp() {
  Fixture f;
  f.Start();
  shim.create_at_once = false;
  auto create = [&f](int32_t minted, int32_t request, uint64_t view, uint32_t token) {
    Writer w;
    w.I32(minted);
    w.I32(request);
    w.ViewToken(view);
    w.I32(800);
    w.I32(600);
    w.Str("https://b/");
    w.Str(nullptr);
    f.host.OnMessages({Op(kOpCreateWindow, token, w)});
  };
  create(kMinted + 5, 43, 10, 20);
  f.Sent();
  Writer ax;
  ax.I32(kMinted + 5);
  ax.I32(4242);
  ax.Bytes("view", 4);
  ax.Bytes("win", 3);
  ax.I32(64);
  f.host.OnMessages({Op(kOpBrowserAccessibilityToken, 60, ax)});
  Check(f.sent.empty(), "before the creation: no reply");

  // The second create_window's call creates the first browser (3), then its own (5).
  shim.created_in_call = {{3, 43}, {5, 44}};
  shim.calls.clear();
  create(kMinted + 6, 44, 11, 21);
  Expect(shim.calls, {"create 44 https://b/ view", "nav_state 3", "nav_state 5", "ax 3 4242 view win"},
         "the held request runs after the op's own events");
  const std::vector<std::string> sent = f.Sent();
  const auto at = [&sent](const std::string& line) { return std::find(sent.begin(), sent.end(), line); };
  const auto first = at("event 2 " + std::to_string(kMinted + 5) + " 43");
  const auto second = at("event 2 " + std::to_string(kMinted + 6) + " 44");
  const auto ack = at("ack 21");
  const auto reply = at("reply 60 10");
  Check(first != sent.end() && second != sent.end() && ack != sent.end() && reply != sent.end() && first < ack &&
            second < ack && ack < reply,
        "both creations, then the op's ack, then the held reply: [" + Join(sent) + "]");
  Check(ack == sent.end() || std::none_of(ack, sent.end(), [](const std::string& line) {
          return line.rfind("mirror ", 0) == 0 || line.rfind("event ", 0) == 0;
        }),
        "no mirror or event of the op after its ack: [" + Join(sent) + "]");
  Expect(f.delegate.calls, {"initialize /root"}, "no bad message");
}

// create_window of `minted` (request 42) into page view `view`; the fake shim makes browser 3.
void CreateWindow(Fixture& f, int32_t minted, uint64_t view) {
  Writer create;
  create.I32(minted);
  create.I32(42);
  create.ViewToken(view);
  create.I32(800);
  create.I32(600);
  create.Str("https://b/");
  create.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 20, create)});
}

// Task 053: the host's page windows never order in. Once the fork hosts a page window's layers
// in the context cmux shows, the host detaches that window (set_detached_hosting(1), API 30);
// a refused hosting detaches nothing, and turning hosting off attaches the window first.
void LayerHostingDetachesThePageWindow() {
  Fixture f;
  f.Start();
  CreateWindow(f, kMinted, 9);
  f.Sent();
  shim.calls.clear();
  auto hosting = [&f](int32_t browser, int32_t enabled, uint32_t token) {
    Writer w;
    w.I32(browser);
    w.I32(enabled);
    f.host.OnMessages({Op(kOpBrowserSetLayerHosting, token, w)});
  };
  hosting(kMinted, 1, 50);
  Expect(shim.calls, {"layer_hosting 3 1", "detached 3 1"},
         "hosting on, for Chromium's id, then the hosted page window detached");
  Check(f.sent.size() == 1 && f.sent[0].op == kOpReply && f.sent[0].token == 50 &&
            Reader(f.sent[0].fields).U32() == 0xC0FFEEu,
        "the REPLY carries the context id");
  f.Sent();

  shim.calls.clear();
  hosting(5, 1, 51);
  Expect(shim.calls, {"layer_hosting 5 1"}, "a refused hosting detaches nothing");
  Expect(f.Sent(), {"reply 51 0"}, "and answers 0");

  shim.calls.clear();
  hosting(kMinted, 0, 52);
  Expect(shim.calls, {"detached 3 0", "layer_hosting 3 0"}, "hosting off attaches the page window first");
  Expect(f.Sent(), {"reply 52 0"}, "and answers 0");

  // A fork that refuses to detach: the page window would stay attached under a window that is
  // never ordered in, which the fork's tracker hides, so hosting goes off again and cmux reads a
  // refused hosting.
  shim.calls.clear();
  shim.refuse_detach = true;
  hosting(kMinted, 1, 54);
  shim.refuse_detach = false;
  Expect(shim.calls, {"layer_hosting 3 1", "detached 3 1", "layer_hosting 3 0"},
         "a refused detach turns hosting off again");
  Expect(f.Sent(), {"reply 54 0"}, "and answers 0, a refused hosting");

  Writer bad;
  bad.I32(kMinted);
  f.host.OnMessages({Op(kOpBrowserSetLayerHosting, 53, bad)});
  Expect(f.delegate.calls, {"initialize /root", "bad a malformed layer hosting op"}, "a malformed op is bad");
}

cmux_host::Header GeometryFrame(int32_t browser, int32_t width, int32_t height, int32_t x, int32_t y) {
  cmux_host::Header frame;
  frame.kind = cmux_host::kGeometry;
  frame.v[0] = width;
  frame.v[1] = height;
  frame.v[2] = x;
  frame.v[3] = y;
  frame.v[4] = 2000;
  cmux_host::input_ring::SetBrowser(&frame, browser);
  return frame;
}

// Task 053: a page view moves or resizes only when its geometry changed: a page that moves gets
// one placement per new place, an unchanged frame costs a comparison, and a frame for a browser
// not created yet waits, the newest one only, for its creation.
void GeometryOnlyOnChange() {
  {
    Fixture f;
    f.Start();
    CreateWindow(f, kMinted, 9);
    f.views.calls.clear();
    Check(f.host.PlaceFrame(GeometryFrame(kMinted, 640, 480, 100, 200)), "a geometry frame is the host's to place");
    Check(f.host.PlaceFrame(GeometryFrame(kMinted, 640, 480, 100, 200)), "the same geometry again");
    Check(f.host.PlaceFrame(GeometryFrame(kMinted, 640, 480, 110, 200)), "the page moved");
    Check(f.host.PlaceFrame(GeometryFrame(kMinted, 0, -4, 110, 200)), "an empty page");
    Expect(f.views.calls, {"place 9 640x480 at 100,200", "place 9 640x480 at 110,200", "place 9 1x1 at 110,200"},
           "one placement per change, an empty page placed at 1 x 1");
    Check(f.host.geometry_stats().frames == 4 && f.host.geometry_stats().applied == 3 &&
              f.host.geometry_stats().unchanged == 1 && f.host.geometry_stats().unplaced == 0,
          "the stats count 4 frames, 3 applied, 1 unchanged");

    cmux_host::Header key;
    key.kind = cmux_host::kKey;
    cmux_host::input_ring::SetBrowser(&key, kMinted);
    Check(!f.host.PlaceFrame(key), "a key is the input dispatch's");
    Check(f.host.PlaceFrame(GeometryFrame(7, 10, 10, 0, 0)) && f.host.geometry_stats().unplaced == 1,
          "a browser with no page view places nothing");

    shim.live = 0;
    Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
    CreateWindow(f, kMinted + 1, 9);
    f.views.calls.clear();
    f.host.PlaceFrame(GeometryFrame(kMinted + 1, 640, 480, 0, 1));
    Expect(f.views.calls, {"place 9 640x480 at 0,1"}, "a page view opened again under the same token is placed again");
  }
  {
    Fixture f;
    f.Start();
    shim.create_at_once = false;
    CreateWindow(f, kMinted + 2, 11);
    f.views.calls.clear();
    f.host.PlaceFrame(GeometryFrame(kMinted + 2, 300, 200, 5, 5));
    f.host.PlaceFrame(GeometryFrame(kMinted + 2, 320, 200, 5, 5));
    Check(f.views.calls.empty(), "no placement before the browser exists");
    Emit(CMUX_SHIM_AFTER_CREATED, 3, 42);
    Expect(f.views.calls, {"place 11 320x200 at 5,5"}, "the creation places the newest geometry once");
    f.host.PlaceFrame(GeometryFrame(kMinted + 2, 320, 200, 5, 5));
    Check(f.views.calls.size() == 1, "and it counts as the view's last geometry");
  }
  {
    // The ring overtakes create_window (not an ordered op): a minted id's geometry that comes
    // before create_window is dispatched still places its page view, at the creation.
    Fixture f;
    f.Start();
    f.host.PlaceFrame(GeometryFrame(kMinted + 3, 500, 400, 7, 8));
    f.host.PlaceFrame(GeometryFrame(kMinted + 3, 510, 400, 7, 8));
    Check(f.views.calls.empty() && f.host.geometry_stats().unplaced == 0, "held, not dropped");
    CreateWindow(f, kMinted + 3, 12);
    Expect(f.views.calls, {"open 12", "place 12 510x400 at 7,8"},
           "create_window's creation places the newest geometry that came before it");

    // A refused create_window drops what it held.
    shim.create_at_once = false;
    shim.create_result = 0;
    f.host.PlaceFrame(GeometryFrame(kMinted + 4, 50, 50, 0, 0));
    CreateWindow(f, kMinted + 4, 13);
    shim.create_result = 1;
    f.views.calls.clear();
    Emit(CMUX_SHIM_AFTER_CREATED, 4, 42);
    Check(f.views.calls.empty(), "a refused create_window's held geometry places nothing");
  }
}

// The geometry counters go to cmux on request (chromium-host-bench.py geometry row).
void GeometryStatsReply() {
  Fixture f;
  f.Start();
  CreateWindow(f, kMinted, 9);
  f.host.PlaceFrame(GeometryFrame(kMinted, 640, 480, 0, 0));
  f.host.PlaceFrame(GeometryFrame(kMinted, 640, 480, 0, 0));
  f.host.PlaceFrame(GeometryFrame(7, 10, 10, 0, 0));
  f.Sent();
  f.host.OnMessages({Op(cmux_host::kOpGeometryStats, 60, Writer())});
  Check(f.sent.size() == 1 && f.sent[0].op == kOpReply && f.sent[0].token == 60, "a REPLY to the stats request");
  if (f.sent.size() == 1) {
    Reader r(f.sent[0].fields);
    const int64_t frames = r.I64(), applied = r.I64(), unchanged = r.I64(), unplaced = r.I64();
    Check(r.ok() && r.AtEnd() && frames == 3 && applied == 1 && unchanged == 1 && unplaced == 1,
          "frames, applied, unchanged, unplaced");
  }
  Writer bad;
  bad.I32(1);
  f.host.OnMessages({Op(cmux_host::kOpGeometryStats, 61, bad)});
  Expect(f.delegate.calls, {"initialize /root", "bad a malformed geometry stats request"}, "fields are bad");
}

void WipeZeroes() {
  std::vector<std::string> secrets = {"hunter2", ""};
  cmux_host::Wipe(secrets);
  Check(secrets[0].empty() && secrets[1].empty(), "Wipe clears every secret");
}

}  // namespace

int main() {
  HelloFirst();
  HelloOfAnotherWire();
  OptionalExports();
  PreinitBeforeInitialize();
  MintedWindow();
  MintedTab();
  DevTools();
  DevToolsPlacementView();
  FocusIsTheShimsEmbedderActiveRule();
  Shutdown();
  BadMessages();
  PopupBoundsByWindow();
  AccessibilityToken();
  AccessibilityTokenBeforeCreation();
  AccessibilityTokenCreatedInsideAnotherOp();
  LayerHostingDetachesThePageWindow();
  GeometryOnlyOnChange();
  GeometryStatsReply();
  WipeZeroes();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-dispatch tests: ok");
  return EXIT_SUCCESS;
}
