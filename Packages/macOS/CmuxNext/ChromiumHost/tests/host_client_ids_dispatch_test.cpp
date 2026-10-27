// The generated host cases (gen-chromium-host-wire.py, from
// tests/fixtures/client_ids) run end to end through ClientIds
// (src/host_client_ids.h, task 019 of plans/cmux-next/chrome-parity/p01-process.md):
// HostContext wires them as host_client_ids.h says, and the stand-in shim
// below behaves as the real one, which runs OnAfterCreated inside tab_add.
// Built and run by scripts/cmux-next/tests/chromium-host-client-ids.test.sh
// with the fixture's generated host_dispatch.inc; needs no CEF.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"
#include "host_client_ids.h"
extern "C" {
#include "cmux_cef_shim.h"  // the fixture header (C, like the real one)
}

namespace cmux_host {

using TlvReader = control::TlvReader;
using TlvWriter = control::TlvWriter;

void Wipe(std::vector<std::string>& secrets) {
  secrets.clear();
}

// The part of the host's HostContext (host_dispatch.h) the generated mint and
// post cases use, on ClientIds.
class HostContext {
 public:
  HostContext() : ids_([this](const ClientIds::Event& event) { sent.push_back(event); }) {}

  int Browser(int32_t client_id) { return ids_.Browser(client_id); }
  void* PageView(uint64_t) { return nullptr; }
  void* OptionalExport(uint16_t) { return nullptr; }
  void Ack(uint32_t) {}
  void Reply(uint32_t, const TlvWriter&) {}
  void PushMirror(uint16_t, const TlvWriter&, const TlvWriter&) {}
  void BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser);
  void BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int32_t request, int64_t started);

  // One op, as HostContext::Dispatch runs it.
  bool Run(uint16_t op, TlvWriter args);
  // The shim's event_fn.
  void Event(int kind, int browser, int request = 0, int64_t a = 0, int64_t b = 0) {
    if (!ids_.FromShim(ClientIds::Event{kind, browser, request, a, b, {}, {}})) bad = true;
  }

  std::vector<ClientIds::Event> sent;
  bool bad = false;

 private:
  ClientIds ids_;
};

}  // namespace cmux_host

#include "host_dispatch.inc"  // generated from the fixture

namespace {

using cmux_host::ClientIds;
using cmux_host::HostContext;
using cmux_host::TlvWriter;
namespace mint = cmux_host::mint;

// The stand-in shim: its browsers from Chromium's 6 (the tests name the windows' 5, 20 and 30), the
// event sink, and what reached it.
HostContext* g_host = nullptr;
int g_next_browser = 6;
int g_next_message = 3;
std::vector<std::pair<int, std::string>> g_loads;
std::vector<int> g_tab_add_anchors;

}  // namespace

extern "C" {

const char* cmux_shim_abi_id(void) {
  return "fixture";
}

int cmux_shim_initialize(void*, cmux_shim_event_fn) {
  return 1;
}

// CefBrowserHost::CreateBrowser: 1 now, the browser in a later AFTER_CREATED;
// request 99 stands for one it refuses.
int cmux_shim_create_window(int request, const char*) {
  return request == 99 ? 0 : 1;
}

// The fork adds the tab and runs its OnAfterCreated before it returns.
int cmux_shim_tab_add(int window_browser_id, const char*, int, int) {
  g_tab_add_anchors.push_back(window_browser_id);
  if (window_browser_id == 0) return 0;
  const int browser = g_next_browser++;
  g_host->Event(CMUX_SHIM_AFTER_CREATED, browser);
  return browser;
}

int cmux_shim_tab_duplicate(int browser_id, int window_browser_id, int) {
  if (browser_id == 0 || window_browser_id == 0) return 0;
  const int browser = g_next_browser++;
  g_host->Event(CMUX_SHIM_AFTER_CREATED, browser);
  return browser;
}

void cmux_shim_load_url(int browser_id, const char* url) {
  g_loads.emplace_back(browser_id, url ? url : "");
}

int cmux_shim_devtools_call(int browser_id, const char*, const char*) {
  return browser_id == 0 ? 0 : g_next_message++;
}

}  // extern "C"

namespace cmux_host {

void HostContext::BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser) {
  const ClientIds::Outcome outcome =
      op == kOpDevtoolsCall ? ids_.BindDevToolsCall(client_browser, minted, result) : ids_.Bind(minted, result);
  if (outcome == ClientIds::Outcome::kBad) bad = true;
}

void HostContext::BindMintedOnEvent(uint16_t, int32_t minted, int event_kind, int32_t request, int64_t started) {
  if (ids_.BindOnEvent(minted, event_kind, request, started) == ClientIds::Outcome::kBad) bad = true;
}

bool HostContext::Run(uint16_t op, TlvWriter args) {
  TlvReader r(args.Take());
  ids_.BeginCall();
  const bool ok = DispatchOp(*this, op, 0, r);
  ids_.EndCall();
  return ok;
}

}  // namespace cmux_host

namespace {

int failures = 0;
#define CHECK(cond)                                                                 \
  do {                                                                              \
    if (!(cond)) {                                                                  \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                                   \
    }                                                                               \
  } while (0)

constexpr int32_t kWindow = mint::kFirstBrowserID;
constexpr int32_t kAdded = mint::kFirstBrowserID + 1;
constexpr int32_t kRefused = mint::kFirstBrowserID + 2;
constexpr int32_t kNoWindow = mint::kFirstBrowserID + 3;

TlvWriter CreateWindow(int32_t minted, int32_t request) {
  TlvWriter w;
  w.I32(minted);
  w.I32(request);
  w.Str("about:blank");
  return w;
}

TlvWriter TabAdd(int32_t minted, int32_t window) {
  TlvWriter w;
  w.I32(minted);
  w.I32(window);
  w.Str("https://example.com/");
  w.I32(-1);
  w.I32(1);
  return w;
}

TlvWriter LoadURL(int32_t browser, const char* url) {
  TlvWriter w;
  w.I32(browser);
  w.Str(url);
  return w;
}

TlvWriter DevToolsCall(int32_t minted, int32_t browser) {
  TlvWriter w;
  w.I32(minted);
  w.I32(browser);
  w.Str("Page.reload");
  w.Str("{}");
  return w;
}

bool AnyFromChromium(const std::vector<ClientIds::Event>& events, int chromium_id) {
  for (const ClientIds::Event& event : events) {
    if (event.browser_id == chromium_id) return true;
  }
  return false;
}

// create_window, its later AFTER_CREATED, then tab_add on that window: the
// tab's AFTER_CREATED, emitted inside the call under Chromium's 6, reaches
// cmux once, under the minted id; a later op naming the minted id reaches
// Chromium's 6.
void ATabAddedToAMintedWindowIsItsMintedIdBothWays() {
  HostContext host;
  g_host = &host;
  CHECK(host.Run(cmux_host::kOpCreateWindow, CreateWindow(kWindow, 41)));
  CHECK(host.sent.empty());
  host.Event(CMUX_SHIM_AFTER_CREATED, 5, 41);  // Chromium made the window's browser
  CHECK(host.sent.size() == 1 && host.sent[0].browser_id == kWindow && host.sent[0].request == 41);

  host.sent.clear();
  CHECK(host.Run(cmux_host::kOpTabAdd, TabAdd(kAdded, kWindow)));
  CHECK(g_tab_add_anchors.back() == 5);
  CHECK(host.sent.size() == 1);
  if (host.sent.size() == 1) {
    CHECK(host.sent[0].kind == CMUX_SHIM_AFTER_CREATED);
    CHECK(host.sent[0].browser_id == kAdded);
  }
  CHECK(!AnyFromChromium(host.sent, 6));

  CHECK(host.Run(cmux_host::kOpLoadUrl, LoadURL(kAdded, "https://example.com/next")));
  CHECK(!g_loads.empty() && g_loads.back().first == 6);
  CHECK(!host.bad);
}

// The anchor closed in the host before cmux saw its BEFORE_CLOSE: tab_add
// reaches the shim with no browser and is refused, and cmux hears
// CREATE_FAILED for the id it minted (its tab shows the failure; nothing
// closes). A refused create_window says which request failed.
void ARefusedCreateReachesCmuxAsCreateFailed() {
  HostContext host;
  g_host = &host;
  CHECK(host.Run(cmux_host::kOpCreateWindow, CreateWindow(kWindow, 41)));
  host.Event(CMUX_SHIM_AFTER_CREATED, 20, 41);
  host.Event(CMUX_SHIM_BEFORE_CLOSE, 20);
  host.sent.clear();

  CHECK(host.Run(cmux_host::kOpTabAdd, TabAdd(kRefused, kWindow)));
  CHECK(g_tab_add_anchors.back() == 0);
  CHECK(host.sent.size() == 1);
  if (host.sent.size() == 1) {
    CHECK(host.sent[0].kind == mint::kEventCreateFailed);
    CHECK(host.sent[0].browser_id == kRefused && host.sent[0].request == 0);
  }
  for (const ClientIds::Event& event : host.sent) CHECK(event.kind != CMUX_SHIM_BEFORE_CLOSE);

  host.sent.clear();
  CHECK(host.Run(cmux_host::kOpCreateWindow, CreateWindow(kNoWindow, 99)));
  CHECK(host.sent.size() == 1);
  if (host.sent.size() == 1) {
    CHECK(host.sent[0].kind == mint::kEventCreateFailed);
    CHECK(host.sent[0].browser_id == kNoWindow && host.sent[0].request == 99);
  }
  CHECK(!host.bad);
}

// devtools_call: the shim's message id is keyed by the call's browser, so its
// DEVTOOLS_RESULT carries the id cmux minted; a call on a closed browser is
// answered at once with a = 0.
void DevToolsCallsResolveByTheMintedMessageId() {
  HostContext host;
  g_host = &host;
  CHECK(host.Run(cmux_host::kOpCreateWindow, CreateWindow(kWindow, 41)));
  host.Event(CMUX_SHIM_AFTER_CREATED, 30, 41);
  host.sent.clear();
  const int message = g_next_message;
  CHECK(host.Run(cmux_host::kOpDevtoolsCall, DevToolsCall(mint::kFirstDevToolsID, kWindow)));
  CHECK(host.sent.empty());
  host.Event(CMUX_SHIM_DEVTOOLS_RESULT, 30, message, 1);
  CHECK(host.sent.size() == 1);
  if (host.sent.size() == 1) {
    CHECK(host.sent[0].browser_id == kWindow && host.sent[0].request == mint::kFirstDevToolsID);
  }

  host.Event(CMUX_SHIM_BEFORE_CLOSE, 30);
  host.sent.clear();
  CHECK(host.Run(cmux_host::kOpDevtoolsCall, DevToolsCall(mint::kFirstDevToolsID + 1, kWindow)));
  CHECK(host.sent.size() == 1);
  if (host.sent.size() == 1) {
    CHECK(host.sent[0].kind == CMUX_SHIM_DEVTOOLS_RESULT);
    CHECK(host.sent[0].browser_id == kWindow && host.sent[0].request == mint::kFirstDevToolsID + 1);
    CHECK(host.sent[0].a == 0);
  }
  CHECK(!host.bad);
}

}  // namespace

int main() {
  ATabAddedToAMintedWindowIsItsMintedIdBothWays();
  ARefusedCreateReachesCmuxAsCreateFailed();
  DevToolsCallsResolveByTheMintedMessageId();
  if (failures != 0) {
    std::fprintf(stderr, "host_client_ids_dispatch_test: %d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::puts("host_client_ids_dispatch_test: ok");
  return EXIT_SUCCESS;
}
