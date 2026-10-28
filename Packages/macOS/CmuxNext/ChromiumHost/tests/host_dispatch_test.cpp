// Checks the Chromium Host's dispatcher (src/host_dispatch.mm) against a
// recording fake of the shim and the generated cases
// (generated/host_dispatch.inc, written by gen-chromium-host-wire.py): cmux's
// HELLO of this wire comes first; the attach mirrors, then the host's HELLO
// with the optional exports its shim has; preinit ops run before
// cmux_shim_initialize and everything else after it, in cmux's order; a
// MIRROR goes out before the EVENT that refreshes it, and both before the
// ack of the op that caused them; client-minted ids map to Chromium's both
// ways; Chromium focuses a page only inside cmux's set_focus; window requests
// go to cmux's pushed policy in Chromium's ids, never to a handler; a page's
// accessibility token comes back in its REPLY; a page window whose layers
// are hosted is detached; a page view moves only when its geometry changed
// (task 053); the host holds its App Nap activity while a page shows;
// the fork's lock delegate reaches cmux as CMUX_SHIM_LOCK
// while cmux's handler is on (task 229); a helper's end goes out as HELPER_EXIT; a bad
// message ends the host. Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
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
#include "host_helper_exits.h"
#include "host_page_activity.h"
#include "host_switches.h"

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
  // The handler the host put in the fork's lock delegate (RecordSetLockHandler).
  cmux_host::LockFn lock_fn = nullptr;
  void* lock_context = nullptr;
  int lock_answer = 1;  // set_lock_handler's return (0: the fork refused it)
  cmux_shim_password_reveal_fn reveal_done = nullptr;  // the latest started reveal's
  void* reveal_ctx = nullptr;
  int reveals_started = 0;
  bool reveal_refuses = false;  // password_reveal returns 0
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
// The fork's page display placement (task 221): records the browser, display and origin.
int cmux_shim_browser_set_page_display(int browser_id, unsigned int display_id, double screen_x, double screen_y) {
  shim.calls.push_back("display " + std::to_string(browser_id) + " " + std::to_string(display_id) + " " +
                       std::to_string(static_cast<int>(screen_x)) + "," + std::to_string(static_cast<int>(screen_y)));
  return 1;
}
int cmux_shim_browser_set_detached_hosting(int browser_id, int enabled) {
  shim.calls.push_back("detached " + std::to_string(browser_id) + " " + std::to_string(enabled));
  return enabled && shim.refuse_detach ? 0 : 1;
}
int cmux_shim_browser_set_page_visibility(int browser_id, int visibility) {
  shim.calls.push_back("visibility " + std::to_string(browser_id) + " " + std::to_string(visibility));
  return 1;
}
void cmux_shim_shutdown(void) { shim.calls.push_back("shutdown"); }
char* cmux_shim_tab_navigation_state(int browser_id) {
  shim.calls.push_back("nav_state " + std::to_string(browser_id));
  return strdup(("state of " + std::to_string(browser_id)).c_str());
}
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_password_reveal(const char* path, const char* id, cmux_shim_password_reveal_fn done, void* ctx) {
  shim.calls.push_back(std::string("reveal ") + (path ? path : "<null>") + " " + (id ? id : "<null>"));
  if (shim.reveal_refuses) return 0;
  shim.reveal_done = done;
  shim.reveal_ctx = ctx;
  ++shim.reveals_started;
  return 1;
}
int cmux_shim_live_browser_count(void) { return shim.live; }
void cmux_shim_set_window_request_policy(const cmux_shim_window_policy_window* windows, int window_count,
                                         const cmux_shim_window_policy_click* clicks, int click_count,
                                         const char* profile_root, int cmd_click, int cmd_shift_click,
                                         int shift_click, int option_click, int middle_click) {
  std::string text = "policy";
  for (int i = 0; i < window_count; ++i) {
    text += " " + std::to_string(windows[i].anchor_browser_id) + ":" + std::to_string(windows[i].opener_browser_id) +
            ":" + std::to_string(windows[i].flags) + ":" + std::string(windows[i].store, windows[i].store_length);
  }
  for (int i = 0; i < click_count; ++i) {
    text += " click " + std::to_string(clicks[i].browser_id) + ":" + std::to_string(clicks[i].gesture) + ":" +
            std::to_string(clicks[i].uptime_ms);
  }
  text += std::string(" root ") + (profile_root ? profile_root : "(null)") + " actions " + std::to_string(cmd_click) +
          "," + std::to_string(cmd_shift_click) + "," + std::to_string(shift_click) + "," +
          std::to_string(option_click) + "," + std::to_string(middle_click);
  shim.calls.push_back(text);
}
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
    Initialize();
    host.Resume();
    Sent();
  }
  // Start up to initialize's call: the host waits for it to return (Resume).
  void Initialize() {
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
  Check(shim.focus_handler_sets > 0 && shim.focus == nullptr && shim.window == nullptr,
        "after initialize no focus handler (task p01-process-032) and no window request handler: the shim "
        "decides by cmux's pushed policy (task 031)");
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
         TabKeys("mirror", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount),
                                        Key("mirror", kOpRendererClientIds, minted), "event 2 " + minted + " 42", "ack 20"}),
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
         TabKeys("forget", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount),
                                        Key("forget", kOpRendererClientIds, minted), "event 3 " + minted + " 0"}),
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
         TabKeys("mirror", minted, {Key("mirror", kOpLiveBrowserCount), Key("mirror", kOpWindowCount),
                                        Key("mirror", kOpRendererClientIds, minted), "event 2 " + minted + " 0", "ack 30"}),
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

// The host installs no focus handler: the shim grants a
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
}

// The pushed window request policy (task 031): the records' browser ids reach
// the shim as Chromium's (a minted tab with no browser yet keeps its id, which
// names no Chromium window, so the shim never picks it), and the
// decision's anchor comes back in cmux's id. cmux's own handler never
// reaches the shim, whatever cmux sends.
void WindowRequestPolicy() {
  Fixture f;
  f.Start();
  Writer add;
  add.I32(kMinted + 1);
  add.I32(3);
  add.Str("https://d/");
  add.I32(-1);
  add.I32(1);
  f.host.OnMessages({Op(kOpTabAdd, 30, add)});  // Chromium's 4
  f.Sent();
  shim.calls.clear();
  Writer policy;
  policy.I32(2);
  policy.I64(kMinted + 1);
  policy.I64(0);
  policy.I64(CMUX_SHIM_WINDOW_CANDIDATE | CMUX_SHIM_WINDOW_LAST_SHOWN);
  policy.Bytes("/p/Profile-A", 12);
  policy.I64(kMinted + 9);  // minted, no browser yet
  policy.I64(kMinted + 1);
  policy.I64(0);
  policy.Bytes("/p/Profile-A", 12);
  policy.I32(1);
  policy.I64(kMinted + 1);
  policy.I64(CMUX_SHIM_GESTURE_CMD_SHIFT);
  policy.I64(1234);
  policy.Str("/p");
  for (int action : {3, 2, 4, 5, 1}) policy.I32(action);
  f.host.OnMessages({Op(kOpSetWindowRequestPolicy, 31, policy)});
  Expect(shim.calls, {"policy 4:0:3:/p/Profile-A " + std::to_string(kMinted + 9) + ":4:0:/p/Profile-A click 4:2:1234 root /p actions 3,2,4,5,1"},
         "the policy reaches the shim in Chromium's ids");
  Expect(f.Sent(), {"ack 31"}, "the policy is a post");

  HostContext::OnShimEvent(&f.host, CMUX_SHIM_WINDOW_REQUEST_RESULT, 4, 77, 4, CMUX_SHIM_WINDOW_INSERT,
                           "https://p/", ";/p/Profile-A");
  Check(f.sent.size() == 1, "one result event");
  int32_t tab = 0;
  if (f.sent.size() == 1) {
    Reader r(f.sent[0].fields);
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    const int64_t anchor = r.I64(), b = r.I64();
    tab = static_cast<int32_t>(static_cast<uint64_t>(b) >> 32);
    Check(kind == CMUX_SHIM_WINDOW_REQUEST_RESULT && browser == kMinted + 1 && request == 77 && anchor == kMinted + 1,
          "the result names the source and the anchor by cmux's ids and keeps Chromium's window id");
    Check(tab == (1 << 30) && (b & 0xffffffff) == CMUX_SHIM_WINDOW_INSERT,
          "an INSERT's result carries the id the host minted for its tab, from the host's range");
  }
  f.Sent();

  // The tab Chromium opens in the anchor's window (77), opened by Chromium's 4: cmux's ids both.
  HostContext::OnShimEvent(&f.host, CMUX_SHIM_AFTER_CREATED, 12, 0, 77, (int64_t{4} << 32) | 3, "", "");
  bool created = false;
  for (const Message& message : f.sent) {
    if (message.op != kOpEvent) continue;
    Reader r(message.fields);
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    const int64_t window = r.I64(), b = r.I64();
    if (kind != CMUX_SHIM_AFTER_CREATED) continue;
    created = true;
    Check(browser == tab && request == 0 && window == 77, "the tab's AFTER_CREATED names it by the minted id");
    Check(static_cast<int32_t>(static_cast<uint64_t>(b) >> 32) == kMinted + 1 && (b & 0xffffffff) == 3,
          "its opener by cmux's id");
  }
  Check(created, "the tab's AFTER_CREATED reaches cmux");
  f.Sent();
  shim.calls.clear();
  Writer load;
  load.I32(tab);
  load.Str("https://q/");
  f.host.OnMessages({Op(kOpLoadUrl, 33, load)});
  Expect(shim.calls, {"load 12 https://q/", "nav_state 12"}, "an op on the minted id reaches Chromium's tab");
  f.Sent();

  Writer install;
  install.I32(1);
  f.host.OnMessages({Op(kOpSetWindowRequestHandler, 32, install)});
  Check(shim.window == nullptr, "cmux's window request handler never reaches the host's shim");
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
  Check(f.delegate.calls.back() == "bad too many requests waiting for a browser's creation",
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

// Task 220: the fork takes a page's visibility only while its window is detached, so the host
// keeps cmux's last value per browser and applies it when it detaches the page window; a refused
// detach applies nothing, and a closed browser's value is gone.
void PageVisibilityAppliesAtTheDetach() {
  Fixture f;
  f.Start();
  CreateWindow(f, kMinted, 9);
  f.Sent();
  auto visibility = [&f](int32_t browser, int32_t value, uint32_t token) {
    Writer w;
    w.I32(browser);
    w.I32(value);
    f.host.OnMessages({Op(kOpBrowserSetPageVisibility, token, w)});
  };
  auto hosting = [&f](int32_t browser, int32_t enabled, uint32_t token) {
    Writer w;
    w.I32(browser);
    w.I32(enabled);
    f.host.OnMessages({Op(kOpBrowserSetLayerHosting, token, w)});
  };
  shim.calls.clear();
  visibility(kMinted, CMUX_SHIM_PAGE_OCCLUDED, 0);
  visibility(kMinted, CMUX_SHIM_PAGE_HIDDEN, 60);
  Expect(shim.calls, {"visibility 3 2", "visibility 3 1"}, "each value goes to the fork, for Chromium's id");
  Expect(f.Sent(), {"ack 60"}, "a post with a token is acked");

  shim.calls.clear();
  hosting(kMinted, 1, 61);
  Expect(shim.calls, {"layer_hosting 3 1", "detached 3 1", "visibility 3 1"},
         "the detach applies cmux's last value, after the detach");
  f.Sent();

  shim.calls.clear();
  shim.refuse_detach = true;
  hosting(kMinted, 1, 62);
  shim.refuse_detach = false;
  Expect(shim.calls, {"layer_hosting 3 1", "detached 3 1", "layer_hosting 3 0"}, "a refused detach applies nothing");
  f.Sent();

  shim.live = 0;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  CreateWindow(f, kMinted, 9);  // the same client id names a new browser
  f.Sent();
  shim.calls.clear();
  hosting(kMinted, 1, 63);
  Expect(shim.calls, {"layer_hosting 3 1", "detached 3 1"}, "a closed browser's value is forgotten");
  f.Sent();

  Writer bad;
  bad.I32(kMinted);
  f.host.OnMessages({Op(kOpBrowserSetPageVisibility, 64, bad)});
  Expect(f.delegate.calls,
         {"initialize /root", "closed", "bad a malformed op " + std::to_string(kOpBrowserSetPageVisibility)},
         "a malformed op is bad");
}

// PageShowActivity's hold as the task 128 tests read it: held or not, per change of level.
PageShowActivity::Hold Recorder(std::vector<bool>& holds) {
  return [&holds](const ActivityState& state) { holds.push_back(state.level != ActivityLevel::kNone); };
}

// Task p14-energy-128: the host holds its App Nap activity while cmux shows one of its pages and
// lets App Nap apply when every page is hidden or occluded. It starts held, through Chromium's
// start; 1 shown page begins it, 0 ends it, and the same count again changes nothing.
void PageShowActivityHoldsWhileAPageShows() {
  {
    std::vector<bool> holds;
    PageShowActivity activity(Recorder(holds));
    Check(activity.held() && holds == std::vector<bool>{true}, "the activity begins at the start");
    activity.SetShownPages(1);
    activity.SetShownPages(2);
    Check(holds.size() == 1, "a shown page while held does not begin it again");
    activity.SetShownPages(0);
    activity.SetShownPages(0);
    Check(!activity.held() && holds == (std::vector<bool>{true, false}), "0 ends it, once");
    activity.SetShownPages(1);
    activity.SetShownPages(1);
    Check(activity.held() && holds == (std::vector<bool>{true, false, true}) && activity.edges() == 3,
          "1 begins it again, once");
  }

  auto visibility = [](Fixture& f, int32_t browser, int32_t value) {
    Writer w;
    w.I32(browser);
    w.I32(value);
    f.host.OnMessages({Op(kOpBrowserSetPageVisibility, 0, w)});
  };
  {
    // Through the dispatcher: the count is cmux's visibility posts, per browser.
    Fixture f;
    std::vector<bool> holds;
    PageShowActivity activity(Recorder(holds));
    f.host.SetPageShowActivity(&activity);
    f.Start();
    Check(!activity.held() && holds == (std::vector<bool>{true, false}),
          "with no page shown once initialize returned, the start's activity ends");
    CreateWindow(f, kMinted, 9);
    f.Sent();
    holds.clear();
    shim.calls.clear();
    visibility(f, kMinted, CMUX_SHIM_PAGE_VISIBLE);
    Check(activity.held() && holds == std::vector<bool>{true}, "a shown page begins it");
    Expect(shim.calls, {"visibility 3 0"}, "and its visibility still goes to the fork");
    visibility(f, kMinted, CMUX_SHIM_PAGE_VISIBLE);
    visibility(f, 5, CMUX_SHIM_PAGE_VISIBLE);
    visibility(f, kMinted, CMUX_SHIM_PAGE_HIDDEN);
    Check(f.host.shown_pages() == 1 && holds.size() == 1, "repeats and a second page do not churn");
    visibility(f, 5, CMUX_SHIM_PAGE_OCCLUDED);
    Check(f.host.shown_pages() == 0 && !activity.held() && holds == (std::vector<bool>{true, false}),
          "every page hidden or occluded ends it");
    visibility(f, 5, CMUX_SHIM_PAGE_HIDDEN);
    Check(holds.size() == 2, "hidden after occluded changes nothing");
    visibility(f, kMinted, CMUX_SHIM_PAGE_VISIBLE);
    Check(activity.held() && holds.size() == 3, "a page shown again begins it");
    shim.live = 0;
    Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
    Check(f.host.shown_pages() == 0 && !activity.held() && holds.size() == 4, "the shown page's close ends it");
    Expect(f.delegate.calls, {"initialize /root", "closed"}, "no bad message");
  }
  {
    // A page shown while Chromium started (its post waited for initialize): the start's activity
    // carries on into the page's, with no end between.
    Fixture f;
    std::vector<bool> holds;
    PageShowActivity activity(Recorder(holds));
    f.host.SetPageShowActivity(&activity);
    f.Initialize();
    visibility(f, 5, CMUX_SHIM_PAGE_VISIBLE);
    Check(f.host.shown_pages() == 0, "the post waits for initialize");
    f.host.Resume();
    Check(f.host.shown_pages() == 1 && activity.held() && holds == std::vector<bool>{true},
          "held from the start through the shown page");
  }
}

// Task p01-process-222: while cmux is the active app the host holds the activity at kActive
// (latency critical), with or without a shown page; a shown page with another app active holds
// kShown; cmux hidden lets App Nap apply. Each change of level is one hold and one log line.
void ActivityFollowsCmuxActiveAndHidden() {
  std::vector<ActivityState> states;
  PageShowActivity activity([&states](const ActivityState& state) { states.push_back(state); });
  auto levels = [&states] {
    std::vector<ActivityLevel> out;
    for (const ActivityState& state : states) out.push_back(state.level);
    return out;
  };
  using L = ActivityLevel;
  Check(levels() == std::vector<L>{L::kShown} && states.back().starting, "the start holds kShown");
  activity.SetApp(true, false);
  Check(levels() == (std::vector<L>{L::kShown, L::kActive}), "cmux active during the start: kActive");
  activity.SetShownPages(0);
  Check(activity.level() == L::kActive && states.size() == 2,
        "the start's end with no page shown keeps kActive while cmux is active");
  activity.SetApp(true, false);
  Check(states.size() == 2, "the same app state again changes nothing");
  activity.SetApp(false, false);
  Check(activity.level() == L::kNone && !activity.held() && states.size() == 3,
        "another app active and no page shown: App Nap may apply");
  activity.SetShownPages(1);
  Check(activity.level() == L::kShown && states.size() == 4, "a shown page with another app active: kShown");
  activity.SetApp(true, false);
  Check(activity.level() == L::kActive && states.size() == 5, "cmux active again: kActive");
  activity.SetShownPages(2);
  Check(states.size() == 5, "a second page while active does not churn");
  activity.SetApp(false, true);
  Check(activity.level() == L::kNone && states.size() == 6, "cmux hidden ends it, pages posted shown or not");
  activity.SetApp(false, false);
  Check(activity.level() == L::kShown && states.size() == 7, "unhidden with its pages shown: kShown");
  Check(activity.edges() == 7, "one edge per change of level");
  Check(ActivityLogLine(states.back()) ==
            "cmux-chromium-host: app nap activity shown (cmux active 0, hidden 0, shown pages 2)\n",
        "the log line names the level and what it follows");
  Check(ActivityLogLine(states.front()) ==
            "cmux-chromium-host: app nap activity shown (cmux active 0, hidden 0, shown pages 0, starting)\n",
        "the start's line says it is starting");

  // Hidden during the start: the start's hold stays until the first count.
  std::vector<bool> holds;
  PageShowActivity starting(Recorder(holds));
  starting.SetApp(false, true);
  Check(starting.level() == L::kShown && holds.size() == 1, "hidden while starting keeps the start's hold");
  starting.SetShownPages(1);
  Check(!starting.held() && holds == (std::vector<bool>{true, false}), "and hidden ends it after the start");
}

// The fork applies a page visibility post to the browser's Chromium window, every tab of it, and
// cmux posts for one tab of each pane's window (CEFPaneHost.anchorBrowser). So the host counts
// shown windows: closing or moving out the posted tab leaves its window's value with the tabs
// that remain, and the value goes with the window's last tab.
void PageShowActivityFollowsTheWindow() {
  {
    PageWindowVisibility windows;
    windows.Post(0, 5, CMUX_SHIM_PAGE_VISIBLE);
    Check(windows.shown() == 1, "a browser with no window known yet is shown alone");
    windows.Placed(5, 9);
    windows.BrowserClosed(5);
    Check(windows.shown() == 1, "placed, its value is its window's and stays at its close");
    windows.Post(9, 6, CMUX_SHIM_PAGE_HIDDEN);
    Check(windows.shown() == 0, "another tab's post replaces the window's value");
    windows.Post(9, 6, CMUX_SHIM_PAGE_VISIBLE);
    windows.WindowGone(9);
    Check(windows.shown() == 0 && windows.empty(), "a gone window's value goes");
  }

  Fixture f;
  std::vector<bool> holds;
  PageShowActivity activity(Recorder(holds));
  f.host.SetPageShowActivity(&activity);
  f.Start();
  auto created = [&f](int browser, int64_t window) {
    HostContext::OnShimEvent(&f.host, CMUX_SHIM_AFTER_CREATED, browser, 0, window, 0, "", "");
  };
  auto closed = [&f](int browser) { HostContext::OnShimEvent(&f.host, CMUX_SHIM_BEFORE_CLOSE, browser, 0, 0, 0, "", ""); };
  // The fork's cmux_tab_event_t: 3 removed from window, 0 inserted into window, 6 window destroyed.
  auto tab_event = [&f](int browser, int kind, int64_t window) {
    HostContext::OnShimEvent(&f.host, CMUX_SHIM_TAB_EVENT, browser, kind, window, 0, "", "");
  };
  auto visibility = [&f](int32_t browser, int32_t value) {
    Writer w;
    w.I32(browser);
    w.I32(value);
    f.host.OnMessages({Op(kOpBrowserSetPageVisibility, 0, w)});
  };
  auto move = [&tab_event](int browser, int64_t from, int64_t to) {
    tab_event(browser, 3, from);
    tab_event(browser, 0, to);
  };

  // A shown pane's window 100 holds [11, 12]; 11, its first tab, has the post and closes while 12 shows.
  created(11, 100);
  created(12, 100);
  visibility(11, CMUX_SHIM_PAGE_VISIBLE);
  Check(activity.held() && f.host.shown_pages() == 1, "a shown window holds the activity");
  closed(11);
  Check(activity.held() && f.host.shown_pages() == 1, "the posted tab's close leaves its window shown");
  visibility(12, CMUX_SHIM_PAGE_HIDDEN);
  Check(!activity.held() && f.host.shown_pages() == 0, "the window's new first tab hides it");
  visibility(12, CMUX_SHIM_PAGE_VISIBLE);
  closed(12);
  Check(!activity.held() && f.host.shown_pages() == 0, "the window's last close ends it");

  // Window 200 holds [21, 22], window 300 [23]: 21, posted shown, moves to 300 with no close.
  created(21, 200);
  created(22, 200);
  created(23, 300);
  visibility(21, CMUX_SHIM_PAGE_VISIBLE);
  visibility(23, CMUX_SHIM_PAGE_VISIBLE);
  move(21, 200, 300);
  Check(f.host.shown_pages() == 2, "a moved tab leaves its old window's value with the tabs that remain");
  visibility(22, CMUX_SHIM_PAGE_HIDDEN);
  visibility(23, CMUX_SHIM_PAGE_HIDDEN);
  Check(!activity.held() && f.host.shown_pages() == 0, "every window hidden after a move: the host may nap");
  visibility(21, CMUX_SHIM_PAGE_VISIBLE);
  Check(activity.held() && f.host.shown_pages() == 1, "the moved tab's post names its new window");
  visibility(23, CMUX_SHIM_PAGE_OCCLUDED);
  Check(!activity.held() && f.host.shown_pages() == 0, "which any of its tabs hides");

  // Window 400's only tab, shown, moves to hidden window 500: window 400 is gone with its value.
  created(31, 400);
  created(32, 500);
  visibility(31, CMUX_SHIM_PAGE_VISIBLE);
  visibility(32, CMUX_SHIM_PAGE_HIDDEN);
  Check(activity.held(), "window 400 shows");
  move(31, 400, 500);
  Check(!activity.held() && f.host.shown_pages() == 0, "an emptied window's value goes");
  tab_event(31, 6, 400);
  Check(f.host.shown_pages() == 0, "its destroy changes nothing");

  // A post before the host knows the tab's window is the tab's alone, and its window's once placed.
  visibility(41, CMUX_SHIM_PAGE_VISIBLE);
  Check(activity.held() && f.host.shown_pages() == 1, "a tab with no window known yet shows alone");
  created(41, 600);
  created(42, 600);
  closed(41);
  Check(activity.held() && f.host.shown_pages() == 1, "placed, its value stays with its window");
  closed(42);
  Check(!activity.held() && f.host.shown_pages() == 0, "and goes with the window's last tab");
  Expect(f.delegate.calls, {"initialize /root", "closed", "closed", "closed", "closed"}, "no bad message");
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

// A helper's end: the event cmux decodes as CEFShimEvent.helperExit, with no
// browser, the pid as its request, the wait status, the extension flag and the helper's switches.
void HelperExitGoesOutAsAnEvent() {
  Fixture f;
  f.Start();
  f.host.HelperExited(HelperExit{4242, 9, HelperIdentity{"gpu-process", "", false}});
  f.host.HelperExited(HelperExit{4243, 1 << 8, HelperIdentity{"renderer", "", true}});
  f.host.HelperExited(HelperExit{4244, 6, HelperIdentity{"utility", "network.mojom.NetworkService", false}});
  Check(f.sent.size() == 3, "one event per helper end, got " + std::to_string(f.sent.size()));
  struct Want {
    int32_t pid;
    int64_t status, flags;
    const char* type;
    const char* sub_type;
  };
  const Want want[] = {{4242, 9, 0, "gpu-process", ""},
                       {4243, 1 << 8, kHelperExitExtension, "renderer", ""},
                       {4244, 6, 0, "utility", "network.mojom.NetworkService"}};
  for (size_t i = 0; i < f.sent.size() && i < 3; ++i) {
    Reader r(f.sent[i].fields);
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    const int64_t a = r.I64(), b = r.I64();
    const std::optional<std::string> s1 = r.Str(), s2 = r.Str();
    Check(f.sent[i].op == kOpEvent && kind == kEventHelperExit && browser == 0 && request == want[i].pid &&
              a == want[i].status && b == want[i].flags && s1 == std::optional<std::string>(want[i].type) &&
              s2 == std::optional<std::string>(want[i].sub_type) && r.ok() && r.AtEnd(),
          "HELPER_EXIT " + std::to_string(i) + " carries pid, status, flags, type and sub type");
  }
}

// The children the watcher follows: a helper's argv from KERN_PROCARGS2, its identity, and one
// end per helper (none for a child that never exec'd a helper, or one not followed).
void HelperTableFollowsChildren() {
  std::string buffer("\x03\x00\x00\x00/path/to/cmux Helper (GPU)\0\0\0\0", 4 + 26 + 4);
  for (const char* argument : {"/path/to/cmux Helper (GPU)", "--type=gpu-process", "--gpu-preferences=x"}) {
    buffer += argument;
    buffer.push_back('\0');
  }
  buffer += "PATH=/usr/bin";  // the environment after argv
  buffer.push_back('\0');
  const std::vector<std::string> argv = ProcArgs(buffer);
  Expect(argv, {"/path/to/cmux Helper (GPU)", "--type=gpu-process", "--gpu-preferences=x"},
         "KERN_PROCARGS2 gives argc arguments after the exec path and its padding");
  Check(ProcArgs(std::string("\x02\x00\x00", 3)).empty(), "a buffer shorter than argc reads nothing");
  Check(HelperIdentityOf(argv) == std::optional<HelperIdentity>(HelperIdentity{"gpu-process", "", false}),
        "a GPU helper's identity");
  Check(HelperIdentityOf({"x", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"}) ==
            std::optional<HelperIdentity>(HelperIdentity{"utility", "network.mojom.NetworkService", false}),
        "a utility's sub type");
  Check(HelperIdentityOf({"x", "--type=renderer", "--extension-process"}) ==
            std::optional<HelperIdentity>(HelperIdentity{"renderer", "", true}),
        "an extension renderer");
  Check(!HelperIdentityOf({"/path/to/cmux Chromium Host"}) && !HelperIdentityOf({"x", "--type="}),
        "no --type, no helper");

  HelperTable table;
  table.Watch(10, std::nullopt);  // forked, not exec'd yet
  table.Watch(11, HelperIdentity{"renderer", "", false});
  table.Watch(12, std::nullopt);  // never a helper
  Check(table.size() == 3 && table.Watches(10) && !table.Watches(13), "three children followed");
  table.Execed(10, HelperIdentity{"gpu-process", "", false});
  table.Execed(13, HelperIdentity{"utility", "", false});  // not followed: stays out
  const std::optional<HelperExit> gpu = table.Exited(10, 9);
  Check(gpu && gpu->pid == 10 && gpu->status == 9 && gpu->identity.type == "gpu-process",
        "the GPU helper's end with its status");
  const std::optional<HelperExit> renderer = table.Exited(11, 0);
  Check(renderer && renderer->identity.type == "renderer", "a renderer's end, normal ones too (cmux judges them)");
  Check(!table.Exited(12, 9) && !table.Exited(13, 9) && !table.Exited(10, 9),
        "no end for a child that never became a helper, one not followed, or one already ended");
  Check(table.size() == 0, "every end leaves the table");
}

// cmux_shim_password_reveal: the shim's done answers
// the op's token with one bytes field, or none when it found no password.
Message RevealRequest(uint32_t token, const char* id) {
  Writer w;
  w.Str("/profile");
  w.Str(id);
  return Op(kOpPasswordReveal, token, w);
}

bool Answers(const std::vector<Message>& sent, uint32_t token, const char* password) {
  if (sent.size() != 1 || sent[0].op != kOpReply || !sent[0].reply || sent[0].token != token) return false;
  if (password == nullptr) return sent[0].fields.empty();
  return sent[0].fields.size() == 1 && sent[0].fields[0].type == control::Type::kBytes &&
         sent[0].fields[0].tag == control::kTagValue && sent[0].fields[0].bytes == password;
}

void PasswordReveal() {
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({RevealRequest(9, "id1")});
    Check(!shim.calls.empty() && shim.calls.back() == "reveal /profile id1", "the reveal reaches the shim");
    Check(f.sent.empty(), "nothing is sent before the shim's done");
    shim.reveal_done(shim.reveal_ctx, "s3cretXX", 6);
    Check(Answers(f.sent, 9, "s3cret"), "done answers the token with the password's bytes");
    f.sent.clear();
    f.host.OnMessages({RevealRequest(10, "id2")});
    shim.reveal_done(shim.reveal_ctx, nullptr, 0);
    Check(Answers(f.sent, 10, nullptr), "not found: a REPLY with no field");
    f.sent.clear();
    shim.reveal_refuses = true;
    f.host.OnMessages({RevealRequest(11, "id3")});
    Check(Answers(f.sent, 11, nullptr), "a reveal the shim did not start is answered at once as not found");
    f.sent.clear();
    f.host.OnMessages({RevealRequest(0, "id4")});
    Check(f.delegate.calls.back() == "bad a malformed password reveal", "a reveal with no token is bad");
  }
  {
    Fixture f;
    f.host.Attach();
    f.host.OnMessages({Hello()});
    f.Sent();
    f.host.OnMessages({RevealRequest(12, "id5")});
    Check(Answers(f.sent, 12, nullptr), "before initialize nothing is started: not found");
    Check(shim.calls.empty(), "before initialize the shim is not asked");
  }
  // A done after the host context is gone sends nothing (ASan: no use after free).
  cmux_shim_password_reveal_fn done = nullptr;
  void* ctx = nullptr;
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({RevealRequest(13, "id6")});
    done = shim.reveal_done;
    ctx = shim.reveal_ctx;
  }
  Check(done != nullptr, "the late reveal started");
  if (done) done(ctx, "late", 4);
  // Past 64 waiting reveals one is answered as not found; the host stays up.
  {
    Fixture f;
    f.Start();
    std::vector<std::pair<cmux_shim_password_reveal_fn, void*>> waiting;
    for (uint32_t token = 100; token < 164; ++token) {
      f.host.OnMessages({RevealRequest(token, "id")});
      waiting.emplace_back(shim.reveal_done, shim.reveal_ctx);
    }
    Check(f.sent.empty() && shim.reveals_started == 64, "64 reveals wait for the shim");
    f.host.OnMessages({RevealRequest(164, "id")});
    Check(Answers(f.sent, 164, nullptr), "the 65th is answered as not found at once");
    Check(shim.reveals_started == 64, "the 65th never reaches the shim");
    bool bad = false;
    for (const std::string& call : f.delegate.calls) bad = bad || call.rfind("bad ", 0) == 0;
    Check(!bad, "too many reveals is not a bad message");
    f.sent.clear();
    for (const auto& [reveal_done, reveal_ctx] : waiting) reveal_done(reveal_ctx, "pw", 2);
    Check(f.sent.size() == 64, "each waiting reveal is answered by its done");
    f.sent.clear();
    f.host.OnMessages({RevealRequest(165, "id")});
    Check(shim.reveals_started == 65 && f.sent.empty(), "answered reveals free their places");
    shim.reveal_done(shim.reveal_ctx, nullptr, 0);
  }
}

void WipeZeroes() {
  std::vector<std::string> secrets = {"hunter2", ""};
  cmux_host::Wipe(secrets);
  Check(secrets[0].empty() && secrets[1].empty(), "Wipe clears every secret");
}

// cmux places a page's detached window on the display its page view shows on (task 221). For a
// browser cmux minted whose creation has not come, the display waits as its accessibility request
// does, and only the newest one: a window dragged across displays before Chromium made the browser
// places it once, on the display it ended on. A created browser's display reaches the fork at once,
// under Chromium's id.
void PageDisplayFollowsCreation() {
  Fixture f;
  f.Start();
  shim.create_at_once = false;
  Writer create;
  create.I32(kMinted + 7);
  create.I32(45);
  create.ViewToken(12);
  create.I32(800);
  create.I32(600);
  create.Str("https://d/");
  create.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 22, create)});
  f.Sent();
  shim.calls.clear();
  auto display = [&f](int32_t browser, uint32_t id, double x, double y) {
    Writer w;
    w.I32(browser);
    w.U32(id);
    w.F64(x);
    w.F64(y);
    f.host.OnMessages({Op(kOpBrowserSetPageDisplay, 0, w)});
  };
  // More displays than kMaxHeldPerBrowser: each replaces the one held before it.
  for (uint32_t id = 1; id <= 20; ++id) display(kMinted + 7, id, 100.0 * id, 50);
  Check(shim.calls.empty(), "before the creation: no fork call");
  Expect(f.delegate.calls, {"initialize /root"}, "held displays never break the bound");

  Emit(CMUX_SHIM_AFTER_CREATED, 3, 45);
  Expect(shim.calls, {"nav_state 3", "display 3 20 2000,50"}, "the creation places the newest display, on Chromium's id");

  shim.calls.clear();
  display(kMinted + 7, 4, -1440, 200);
  Expect(shim.calls, {"display 3 4 -1440,200"}, "a created browser's display goes to the fork at once");
}

// The host shim's cmux_shim_set_energy_saver, as SetEnergySaver takes it.
int RecordEnergySaver(int enabled, const char* exempt_scheme) {
  shim.calls.push_back("saver " + std::to_string(enabled) + " " + (exempt_scheme ? exempt_scheme : "<null>"));
  return 1;
}

Message EnergySaverOp(uint32_t token, int32_t version, int32_t enabled, const char* scheme) {
  Writer w;
  w.I32(version);
  w.I32(enabled);
  w.Str(scheme);
  return Op(kOpEnergySaver, token, w);
}

// The app's Energy Saver reaches the host's fork once CefInitialize returned, on each edge cmux
// sends; the HELLO says whether the fork has it, and a host without it takes the op and changes
// nothing. A frame with no version (0) or with fields version 1 does not have is bad.
void EnergySaverReachesTheFork() {
  {
    Fixture f;
    f.host.SetEnergySaver(&RecordEnergySaver);
    f.host.Attach();
    const std::vector<std::string> sent = f.Sent();
    Check(!sent.empty() && sent.back() == "hello cmux_shim_tab_set_frozen " + std::string(kEnergySaverHelloName),
          "a host whose fork has the saver lists it in its hello: " + Join(sent));
    f.host.OnMessages({Hello()});
    f.host.OnMessages({EnergySaverOp(0, kEnergySaverVersion, 1, "cmux-page")});
    Check(shim.calls.empty(), "before initialize the saver waits");
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    f.host.OnMessages({Op(kOpInitialize, 1, init)});
    Check(shim.calls.empty(), "while initialize runs the saver waits");
    f.host.Resume();
    Expect(shim.calls, {"saver 1 cmux-page"}, "after initialize the saver reaches the fork");
    shim.calls.clear();
    f.Sent();
    f.host.OnMessages({EnergySaverOp(0, kEnergySaverVersion, 0, "cmux-page"),
                       EnergySaverOp(7, kEnergySaverVersion, 1, nullptr)});
    Expect(shim.calls, {"saver 0 cmux-page", "saver 1 <null>"}, "each edge, in order; no scheme is no exemption");
    Expect(f.Sent(), {"reply 7 1"}, "a token is answered with the fork call's result");

    // A later version only appends fields: the host reads version 1's and applies them.
    shim.calls.clear();
    Writer later;
    later.I32(kEnergySaverVersion + 1);
    later.I32(0);
    later.Str("cmux-page");
    later.I32(30);
    f.host.OnMessages({Op(kOpEnergySaver, 0, later)});
    Expect(shim.calls, {"saver 0 cmux-page"}, "a later version's frame applies its version 1 fields");
    Expect(f.delegate.calls, {"initialize /root"}, "and is not bad");
  }
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({EnergySaverOp(9, kEnergySaverVersion, 1, "cmux-page")});
    Check(shim.calls.empty(), "a host whose fork has no saver calls nothing");
    Expect(f.Sent(), {"reply 9 0"}, "and answers 0");
  }
  auto bad = [](Message message, const char* what) {
    Fixture f;
    f.host.SetEnergySaver(&RecordEnergySaver);
    f.Start();
    f.host.OnMessages({std::move(message)});
    Check(shim.calls.empty(), std::string(what) + ": nothing reaches the fork");
    Expect(f.delegate.calls, {"initialize /root", "bad a malformed energy saver"}, what);
  };
  bad(EnergySaverOp(0, 0, 1, "cmux-page"), "a frame with no version");
  bad(EnergySaverOp(0, -1, 1, "cmux-page"), "a negative version");
  bad(EnergySaverOp(0, kEnergySaverVersion, 2, "cmux-page"), "enabled neither 0 nor 1");
  {
    Writer extra;
    extra.I32(kEnergySaverVersion);
    extra.I32(1);
    extra.Str(nullptr);
    extra.I32(30);
    bad(Op(kOpEnergySaver, 0, extra), "version 1 with a field it does not have");
  }
  {
    Writer short_frame;
    short_frame.I32(kEnergySaverVersion);
    bad(Op(kOpEnergySaver, 0, short_frame), "a frame without its fields");
  }
}

int RecordSetLockHandler(cmux_host::LockFn fn, void* context) {
  shim.calls.push_back(fn ? "lock_handler on" : "lock_handler off");
  shim.lock_fn = fn;
  shim.lock_context = context;
  return shim.lock_answer;
}

Message LockHandlerOp(uint32_t token, int32_t installed) {
  Writer w;
  w.I32(installed);
  return Op(kOpSetLockHandler, token, w);
}

// "<kind> <browser> <request> <a> <b>" of each EVENT among `sent`.
std::vector<std::string> Events(const std::vector<Message>& sent) {
  std::vector<std::string> out;
  for (const Message& m : sent) {
    if (m.op != kOpEvent) continue;
    Reader r(m.fields);
    const int kind = r.I32(), browser = r.I32(), request = r.I32();
    const int64_t a = r.I64(), b = r.I64();
    out.push_back(std::to_string(kind) + " " + std::to_string(browser) + " " + std::to_string(request) + " " +
                  std::to_string(a) + " " + std::to_string(b));
  }
  return out;
}

// Task 229: a host whose fork has the lock delegate lists kLocksHelloName; cmux's handler goes
// into the fork once initialize returned and out again; each call of the delegate reaches cmux
// as CMUX_SHIM_LOCK with cmux's id of the browser, the event as request and the detail as a; a
// host without the delegate takes the op and calls nothing; a malformed op is bad.
void LocksReachCmux() {
  {
    Fixture f;
    f.host.SetLockHandler(&RecordSetLockHandler);
    f.host.Attach();
    const std::vector<std::string> sent = f.Sent();
    Check(!sent.empty() && sent.back() == "hello cmux_shim_tab_set_frozen " + std::string(kLocksHelloName),
          "a host whose fork has the lock delegate lists it in its hello: " + Join(sent));
    f.host.OnMessages({Hello()});
    f.host.OnMessages({LockHandlerOp(0, 1)});
    Check(shim.calls.empty(), "before initialize the handler waits");
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    f.host.OnMessages({Op(kOpInitialize, 1, init)});
    f.host.Resume();
    Expect(shim.calls, {"lock_handler on"}, "after initialize the host's handler is in the fork");
    Check(shim.lock_fn == &HostContext::OnLock && shim.lock_context == &f.host, "the host's own handler, with the host");
    f.Sent();

    CreateWindow(f, kMinted, 9);  // Chromium's 3 is cmux's kMinted
    f.sent.clear();
    shim.lock_fn(shim.lock_context, CMUX_SHIM_POINTER_LOCK_REQUESTED, 3, 1);
    shim.lock_fn(shim.lock_context, CMUX_SHIM_KEYBOARD_LOCK_REQUESTED, 3, 1);
    shim.lock_fn(shim.lock_context, CMUX_SHIM_POINTER_UNLOCKED, 3, 0);
    shim.lock_fn(shim.lock_context, CMUX_SHIM_KEYBOARD_UNLOCKED, 77, 0);  // a browser cmux did not mint
    const std::string lock = std::to_string(CMUX_SHIM_LOCK);
    const std::string minted = std::to_string(kMinted);
    Expect(Events(f.sent),
           {lock + " " + minted + " 0 1 0", lock + " " + minted + " 2 1 0", lock + " " + minted + " 1 0 0",
            lock + " 77 3 0 0"},
           "each call of the delegate is one CMUX_SHIM_LOCK, cmux's browser id, the event and its detail");
    f.sent.clear();

    shim.calls.clear();
    f.host.OnMessages({LockHandlerOp(31, 0)});
    Expect(shim.calls, {"lock_handler off"}, "cmux's handler off takes the host's out of the fork");
    Expect(f.Sent(), {"ack 31"}, "a token is acked");

    shim.calls.clear();
    shim.lock_answer = 0;
    f.host.OnMessages({LockHandlerOp(0, 1)});
    Expect(shim.calls, {"lock_handler on"}, "a refused handler is logged, not bad");
    Expect(f.delegate.calls, {"initialize /root"}, "and the host goes on");
  }
  {
    Fixture f;
    f.Start();
    f.host.OnMessages({LockHandlerOp(32, 1)});
    Check(shim.calls.empty(), "a host whose fork has no lock delegate calls nothing");
    Expect(f.Sent(), {"ack 32"}, "and acks the op");
  }
  {
    Fixture f;
    f.host.SetLockHandler(&RecordSetLockHandler);
    f.Start();
    f.host.OnMessages({LockHandlerOp(0, 2)});
    Check(shim.calls.empty(), "installed neither 0 nor 1: nothing reaches the fork");
    Expect(f.delegate.calls, {"initialize /root", "bad a malformed lock handler"}, "and it is bad");
  }
}

// The switches the host starts Chromium with: cmux's set, without the external pump's slice (the
// host runs CefRunMessageLoop), with TimerSlackMac on (host_switches.h).
void HostSwitchesFitTheHostsLoop() {
  const std::vector<std::string> app = {"cmux-tabbed-windows", "cmux-pump-time-slice-us=2000",
                                        "enable-features=AlignWakeUps,BatterySaverModeAlignWakeUps",
                                        "disable-stack-profiler"};
  const std::vector<std::string> want = {"cmux-tabbed-windows",
                                         "enable-features=AlignWakeUps,BatterySaverModeAlignWakeUps",
                                         "disable-stack-profiler", "enable-features=TimerSlackMac"};
  Expect(cmux_host::HostSwitches(app), want, "the app's switches fitted to the host's message loop");
  Expect(cmux_host::HostSwitches({}), {"enable-features=TimerSlackMac"}, "TimerSlackMac with no app switches");
}

// The log the host's Chromium writes: the spawn's --log-file when INITIALIZE
// names none, as cmux's runtime does in host mode, so the supervisor finds a
// crashed host's last lines there (host_switches.h).
void HostLogFileIsTheSpawnsUnlessInitializeNamesOne() {
  const std::string spawn = "/root/ChromiumHost/chromium-host.log";
  Check(cmux_host::HostLogFile(std::nullopt, spawn) == spawn, "no log in INITIALIZE: the spawn's");
  Check(cmux_host::HostLogFile(std::string(), spawn) == spawn, "an empty log in INITIALIZE: the spawn's");
  Check(cmux_host::HostLogFile(std::string("/a/cef.log"), spawn) == "/a/cef.log", "INITIALIZE's log wins");
  Check(cmux_host::HostLogFile(std::nullopt, "").empty(), "no log anywhere: none");
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
  WindowRequestPolicy();
  Shutdown();
  BadMessages();
  PopupBoundsByWindow();
  AccessibilityToken();
  AccessibilityTokenBeforeCreation();
  AccessibilityTokenCreatedInsideAnotherOp();
  PageDisplayFollowsCreation();
  LayerHostingDetachesThePageWindow();
  PageVisibilityAppliesAtTheDetach();
  PageShowActivityHoldsWhileAPageShows();
  PageShowActivityFollowsTheWindow();
  ActivityFollowsCmuxActiveAndHidden();
  GeometryOnlyOnChange();
  GeometryStatsReply();
  PasswordReveal();
  WipeZeroes();
  HelperExitGoesOutAsAnEvent();
  HelperTableFollowsChildren();
  EnergySaverReachesTheFork();
  LocksReachCmux();
  HostSwitchesFitTheHostsLoop();
  HostLogFileIsTheSpawnsUnlessInitializeNamesOne();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-dispatch tests: ok");
  return EXIT_SUCCESS;
}
