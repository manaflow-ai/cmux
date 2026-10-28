// Checks the Chromium Host's provider link (src/host_provider_link.h and
// src/host_provider_link.mm): its frames and op
// encode and decode; AgentRelays sends a relayed page's commands to the shim,
// answers a refused one with a CDP error, takes the page's replies and events
// off cmux's stream and keeps the page's watch on while either side wants it;
// through the dispatcher (src/host_dispatch.mm) with a fake shim, the HELLO
// lists kProviderLinkHelloName, kOpProviderLink dials, cmux's own replies and
// watched events still reach it, a relayed page's never do, and a page that
// closes ends its relay; and the transport dials a fake browser host, proves
// the credential, relays both ways off the UI thread in batches, and refuses
// a socket whose peer is not the browser host. Whether 1,000 CDP messages a
// second add 0 cmux main-thread turns is the browser-use-perf bench in host
// mode (fleet).
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_provider_link.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;
using cmux_host::control::Message;
using Writer = cmux_host::control::TlvWriter;

constexpr int32_t kMinted = 1 << 20;
constexpr int kChromiumBrowser = 3;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The fake shim's DevTools calls.
struct Shim {
  HostContext* host = nullptr;
  std::vector<std::pair<int, std::string>> sends;
  std::vector<std::pair<int, int>> watches;
  int send_result = 1;
  int live = 0;
} fake;

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++fake.live;
  HostContext::OnShimEvent(fake.host, CMUX_SHIM_AFTER_CREATED, kChromiumBrowser, request, 0, 0, "", "");
  return 1;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return fake.live; }
void cmux_shim_devtools_watch_events(int browser_id, int enabled) { fake.watches.emplace_back(browser_id, enabled); }
int cmux_shim_devtools_send(int browser_id, const char* message) {
  fake.sends.emplace_back(browser_id, message ? message : "");
  return fake.send_result;
}
}

namespace {

// --- frames and the op -------------------------------------------------------------------------

void FramesEncodeAndDecode() {
  const std::string message = "{\"id\":1610612736,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"\\\"a\\\"\"}}";
  const std::string cdp = EncodeRelayCdp("tab-1", message);
  std::optional<RelayFrame> frame = DecodeRelayFrame(cdp);
  Check(frame && frame->kind == RelayFrame::Kind::kCdp, "a cdp frame decodes");
  Check(frame && frame->target == "tab-1" && frame->message == message, "the message survives its escaping");

  frame = DecodeRelayFrame("{\"t\":\"relay.attach\",\"targetId\":\"tab-1\",\"browser\":1048576}");
  Check(frame && frame->kind == RelayFrame::Kind::kAttach && frame->browser == kMinted, "relay.attach decodes");
  Check(!DecodeRelayFrame("{\"t\":\"relay.attach\",\"targetId\":\"tab-1\"}"), "relay.attach needs its browser");
  Check(!DecodeRelayFrame("{\"t\":\"relay.attach\",\"targetId\":\"tab-1\",\"browser\":-1}"), "and a positive one");
  Check(!DecodeRelayFrame("{\"t\":\"cdp\",\"targetId\":\"tab-1\"}"), "cdp needs its message");
  Check(!DecodeRelayFrame("{\"t\":\"cdp\",\"targetId\":\"tab-1\",\"message\":\"x\"} trailing"), "one object only");
  Check(!DecodeRelayFrame("[1]") && !DecodeRelayFrame("{\"targetId\":\"x\"}"), "an object with a tag");
  frame = DecodeRelayFrame("{\"t\":\"relay.hello.ack\"}");
  Check(frame && frame->kind == RelayFrame::Kind::kHelloAck, "relay.hello.ack decodes");
  frame = DecodeRelayFrame("{\"t\":\"newer\",\"nested\":{\"a\":[1,{\"b\":\"}\"}]}}");
  Check(frame && frame->kind == RelayFrame::Kind::kOther, "a newer frame is skipped, nested values and all");

  size_t end = 0;
  std::optional<std::string> text = relay_json::ReadString("\"\\ud83d\\ude00 \\ud800 \\u00e9\"", 0, &end);
  Check(text && *text == "\xF0\x9F\x98\x80 \xEF\xBF\xBD \xC3\xA9", "surrogate pairs join, a lone one is U+FFFD");

  const std::string hello = EncodeRelayHello("L1", "c\"red");
  Check(hello == "{\"t\":\"relay.hello\",\"version\":1,\"link\":\"L1\",\"credential\":\"c\\\"red\"}", "relay.hello");
  Check(EncodeRelayClosed("t\n", "gone") == "{\"t\":\"relay.closed\",\"targetId\":\"t\\n\",\"reason\":\"gone\"}",
        "relay.closed");
  Check(RelayFrameBytes("ab") == std::string("\0\0\0\2ab", 6), "a big-endian length first");

  std::optional<std::string> error =
      DevToolsErrorReply("{\"id\":1610612737,\"sessionId\":\"S\",\"method\":\"X\"}", "no browser");
  Check(error && *error == "{\"id\":1610612737,\"error\":{\"code\":-32000,\"message\":\"no browser\"},\"sessionId\":\"S\"}",
        "an error reply keeps the id and the session");
  Check(!DevToolsErrorReply("{\"method\":\"X\"}", "x"), "no id: no reply");
}

void TheOpEncodesAndDecodes() {
  ProviderLinkConfig config;
  config.socket = "/tmp/bh/browser-host-provider.sock";
  config.credential = std::string(64, 'a');
  config.link_id = "L1";
  config.host_pid = 10;
  config.listener_pid = 11;
  Writer w;
  WriteProviderLink(config, &w);
  std::optional<ProviderLinkConfig> read = DecodeProviderLink(w.fields());
  Check(read && *read == config, "kOpProviderLink round trips");

  ProviderLinkConfig none;
  Writer off;
  WriteProviderLink(none, &off);
  read = DecodeProviderLink(off.fields());
  Check(read && !read->socket, "no socket ends the link");

  Writer bad;
  bad.I32(0);
  Check(!DecodeProviderLink(bad.fields()), "version 0 is malformed");
  Writer extra;
  WriteProviderLink(config, &extra);
  extra.I32(1);
  Check(!DecodeProviderLink(extra.fields()), "version 1 with more fields is malformed");
  Writer newer;
  newer.I32(2);
  newer.Str("/s");
  newer.Str("c");
  newer.Str("L");
  newer.I32(1);
  newer.I32(2);
  newer.I32(99);
  Check(DecodeProviderLink(newer.fields()).has_value(), "a later version's extra fields are left");
  ProviderLinkConfig empty = config;
  empty.credential.clear();
  Writer blank;
  WriteProviderLink(empty, &blank);
  Check(!DecodeProviderLink(blank.fields()), "a socket needs a credential");
  ProviderLinkConfig unnamed = config;
  unnamed.link_id.clear();
  Writer anonymous;
  WriteProviderLink(unnamed, &anonymous);
  Check(!DecodeProviderLink(anonymous.fields()), "and a link id");
}

// --- AgentRelays alone -------------------------------------------------------------------------

struct Relays {
  std::vector<std::string> written;
  AgentRelays relays{AgentRelays::Calls{
      [](int32_t client) { return client == kMinted ? kChromiumBrowser : client; },
      [](int browser, const char* message) { return cmux_shim_devtools_send(browser, message); },
      [](int browser, int enabled) { cmux_shim_devtools_watch_events(browser, enabled); },
      [this](std::string json) { written.push_back(std::move(json)); }}};

  void Frame(const std::string& json) {
    std::optional<RelayFrame> frame = DecodeRelayFrame(json);
    Check(frame.has_value(), "a test frame decodes: " + json);
    if (frame) relays.OnFrame(*frame);
  }
};

void RelaysAPagesCommandsAndTakesItsMessages() {
  fake = Shim();
  Relays r;
  r.Frame("{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":1048576}");
  Check(fake.watches.size() == 1 && fake.watches[0] == std::make_pair(kChromiumBrowser, 1),
        "an attached page's events are watched");
  r.Frame(EncodeRelayCdp("T", "{\"id\":1610612736,\"method\":\"Page.enable\"}"));
  Check(fake.sends.size() == 1 && fake.sends[0].first == kChromiumBrowser, "a command goes to the page's browser");
  Check(r.written.empty(), "a sent command needs no answer from the host");

  fake.send_result = 0;
  r.Frame(EncodeRelayCdp("T", "{\"id\":1610612737,\"method\":\"Page.enable\"}"));
  Check(r.written.size() == 1 && r.written[0].find("the tab's page has no browser") != std::string::npos,
        "a command the shim cannot send gets a CDP error");
  fake.send_result = -1;
  r.Frame(EncodeRelayCdp("T", "{\"id\":1610612738,\"method\":\"Page.enable\"}"));
  Check(r.written.size() == 2 && r.written[1].find("Chromium refused") != std::string::npos, "a refused one too");
  r.Frame(EncodeRelayCdp("U", "{\"id\":1610612739,\"method\":\"Page.enable\"}"));
  Check(r.written.size() == 3 && r.written[2].find("not attached") != std::string::npos, "a tab not attached too");
  r.written.clear();

  Check(r.relays.TakeDevToolsMessage(kMinted, "{\"id\":1610612736,\"result\":{}}"), "the link's reply is taken");
  Check(r.written.size() == 1, "and written to the link");
  Check(!r.relays.TakeDevToolsMessage(kMinted, "{\"id\":1073741824,\"result\":{}}"),
        "a reply of cmux's own relay stays cmux's");
  Check(r.relays.TakeDevToolsMessage(kMinted, "{\"method\":\"Page.loadEventFired\",\"params\":{}}"),
        "an event cmux does not watch is the link's alone");
  Check(r.written.size() == 2, "the event went to the link");
  Check(r.relays.CmuxWatch(kMinted, true) == 1, "cmux watches the page too");
  Check(!r.relays.TakeDevToolsMessage(kMinted, "{\"method\":\"Page.frameNavigated\",\"params\":{}}"),
        "an event cmux watches reaches it too");
  Check(r.written.size() == 3, "and the link");
  Check(!r.relays.TakeDevToolsMessage(7, "{\"method\":\"Page.frameNavigated\"}"), "a page not relayed is cmux's");
  Check(r.relays.CmuxWatch(kMinted, false) == 1, "the relay keeps the watch on when cmux stops");

  fake.watches.clear();
  r.Frame("{\"t\":\"relay.detach\",\"targetId\":\"T\"}");
  Check(fake.watches.size() == 1 && fake.watches[0].second == 0, "a detach gives the page cmux's watch back");
  Check(r.relays.relayed() == 0 && !r.relays.TakeDevToolsMessage(kMinted, "{\"id\":1610612740}"),
        "nothing is taken after it");
  Check(r.relays.CmuxWatch(kMinted, false) == 0, "and the watch follows cmux alone");

  r.Frame("{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":1048576}");
  r.written.clear();
  r.relays.BrowserClosed(kMinted);
  Check(r.written.size() == 1 && r.written[0].find("relay.closed") != std::string::npos, "a closed page ends its relay");
  Check(r.relays.relayed() == 0, "and is no longer relayed");

  r.Frame("{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":1048576}");
  r.Frame("{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":9}");
  Check(r.relays.relayed() == 1 && r.relays.Relays(9) && !r.relays.Relays(kMinted), "a target names one page");
  r.relays.LinkEnded();
  Check(r.relays.relayed() == 0, "the link's end drops every relay");
}

// --- through the dispatcher --------------------------------------------------------------------

struct Delegate : HostDelegate {
  void Initialize(InitializeRequest) override {}
  void Quit() override {}
  void BrowserClosed() override {}
  void BadMessage(const std::string& what) override { bad.push_back(what); }
  std::vector<std::string> bad;
};

struct Views : PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const PageGeometry&) override {}
};

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

struct Fixture {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  Relays relays;
  std::vector<ProviderLinkConfig> dialed;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr};
  std::vector<std::string> hello_exports;

  Fixture() {
    fake = Shim();
    fake.host = &host;
    host.SetProviderLink(&relays.relays, [this](const ProviderLinkConfig& config) { dialed.push_back(config); });
    host.Attach();
    for (const Message& m : sent) {
      if (m.op != control::kOpHello) continue;
      control::TlvReader r(m.fields);
      r.Str();
      hello_exports = r.StrList();
    }
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host.OnMessages({Op(control::kOpHello, 0, hello)});
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host.OnMessages({Op(kOpInitialize, 1, init)});
    host.Resume();
    Writer create;
    create.I32(kMinted);
    create.I32(42);
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host.OnMessages({Op(kOpCreateWindow, 2, create)});
    sent.clear();
  }

  // The DEVTOOLS_EVENT messages cmux got since the last call.
  std::vector<std::string> CmuxDevTools() {
    std::vector<std::string> out;
    for (const Message& m : sent) {
      if (m.op != kOpEvent) continue;
      control::TlvReader r(m.fields);
      const int32_t kind = r.I32();
      const int32_t browser = r.I32();
      r.I32();
      r.I64();
      r.I64();
      std::optional<std::string> s1 = r.Str();
      r.Str();
      if (kind == CMUX_SHIM_DEVTOOLS_EVENT) {
        Check(browser == kMinted, "cmux gets its own id");
        out.push_back(s1.value_or(""));
      }
    }
    sent.clear();
    return out;
  }

  void DevTools(const char* json) {
    HostContext::OnShimEvent(&host, CMUX_SHIM_DEVTOOLS_EVENT, kChromiumBrowser, 0, 0, 0, json, nullptr);
  }
};

void TheDispatcherRelaysThroughTheLink() {
  Fixture f;
  bool listed = false;
  for (const std::string& name : f.hello_exports) listed |= name == kProviderLinkHelloName;
  Check(listed, "the HELLO lists the provider link");

  ProviderLinkConfig config;
  config.socket = "/tmp/s.sock";
  config.credential = "cred";
  config.link_id = "L1";
  config.host_pid = 5;
  Writer link;
  WriteProviderLink(config, &link);
  f.host.OnMessages({Op(kOpProviderLink, 0, link)});
  Check(f.dialed.size() == 1 && f.dialed[0] == config, "kOpProviderLink dials");
  {
    Fixture ending;
    Writer malformed;
    malformed.I32(0);
    ending.host.OnMessages({Op(kOpProviderLink, 0, malformed)});
    Check(ending.delegate.bad.size() == 1 && ending.dialed.empty(), "a malformed one is a bad message");
    fake.host = &f.host;
  }

  f.relays.Frame("{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":1048576}");
  f.DevTools("{\"id\":1610612736,\"result\":{}}");
  f.DevTools("{\"method\":\"Page.loadEventFired\",\"params\":{}}");
  Check(f.CmuxDevTools().empty(), "a relayed page's reply and event never reach cmux");
  Check(f.relays.written.size() == 2, "they go on the link");
  f.DevTools("{\"id\":1073741824,\"result\":{}}");
  Check(f.CmuxDevTools().size() == 1, "cmux's own relay still gets its reply");

  fake.watches.clear();
  Writer watch;
  watch.I32(kMinted);
  watch.I32(0);
  f.host.OnMessages({Op(kOpDevtoolsWatchEvents, 3, watch)});
  Check(fake.watches.size() == 1 && fake.watches[0] == std::make_pair(kChromiumBrowser, 1),
        "cmux's unwatch keeps a relayed page watched");
  Writer on;
  on.I32(kMinted);
  on.I32(1);
  f.host.OnMessages({Op(kOpDevtoolsWatchEvents, 4, on)});
  f.DevTools("{\"method\":\"Page.frameNavigated\",\"params\":{}}");
  Check(f.CmuxDevTools().size() == 1, "a page cmux watches gets its events too");

  f.relays.written.clear();
  HostContext::OnShimEvent(&f.host, CMUX_SHIM_BEFORE_CLOSE, kChromiumBrowser, 0, 0, 0, "", "");
  Check(f.relays.written.size() == 1 && f.relays.written[0].find("relay.closed") != std::string::npos,
        "a page that closes ends its relay");
  Check(f.delegate.bad.empty(), "no bad message");
}

// --- the transport -----------------------------------------------------------------------------

// The UI thread of the test: posted tasks wait here until Pump runs them.
struct MainQueue {
  std::mutex mutex;
  std::condition_variable ready;
  std::deque<std::function<void()>> tasks;

  void Post(std::function<void()> task) {
    std::lock_guard<std::mutex> lock(mutex);
    tasks.push_back(std::move(task));
    ready.notify_all();
  }

  // Runs tasks until `done` or the deadline; false at the deadline.
  bool PumpUntil(const std::function<bool()>& done) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!done()) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex);
        if (!ready.wait_until(lock, deadline, [&] { return !tasks.empty(); })) return false;
        task = std::move(tasks.front());
        tasks.pop_front();
      }
      task();
    }
    return true;
  }
};

bool ReadExact(int fd, char* out, size_t size) {
  size_t got = 0;
  while (got < size) {
    const ssize_t n = ::read(fd, out + got, size - got);
    if (n <= 0) return false;
    got += static_cast<size_t>(n);
  }
  return true;
}

std::optional<std::string> ReadFrame(int fd) {
  unsigned char header[4];
  if (!ReadExact(fd, reinterpret_cast<char*>(header), 4)) return std::nullopt;
  const size_t length = (size_t{header[0]} << 24) | (size_t{header[1]} << 16) | (size_t{header[2]} << 8) | header[3];
  std::string body(length, '\0');
  if (!ReadExact(fd, body.data(), length)) return std::nullopt;
  return body;
}

void SendFrame(int fd, const std::string& json) {
  const std::string bytes = RelayFrameBytes(json);
  Check(::write(fd, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()), "the fake host writes");
}

// A fake browser host on a fresh socket: it acks a relay.hello with
// `credential`, then sends `frames` and records what it reads.
struct FakeBrowserHost {
  std::string path;
  int listener = -1;
  std::thread thread;
  std::mutex mutex;
  std::vector<std::string> read;
  std::string hello;

  FakeBrowserHost(const std::string& credential, std::vector<std::string> frames) {
    path = "/tmp/cmux-provider-link-" + std::to_string(::getpid()) + "-" + std::to_string(++count) + ".sock";
    ::unlink(path.c_str());
    listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    Check(::bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof address) == 0, "the fake binds");
    Check(::listen(listener, 4) == 0, "the fake listens");
    thread = std::thread([this, credential, frames] {
      const int fd = ::accept(listener, nullptr, nullptr);
      if (fd < 0) return;
      std::optional<std::string> first = ReadFrame(fd);
      {
        std::lock_guard<std::mutex> lock(mutex);
        hello = first.value_or("");
      }
      if (first && first->find("\"credential\":\"" + credential + "\"") != std::string::npos) {
        SendFrame(fd, "{\"t\":\"relay.hello.ack\"}");
        for (const std::string& frame : frames) SendFrame(fd, frame);
        while (std::optional<std::string> frame = ReadFrame(fd)) {
          std::lock_guard<std::mutex> lock(mutex);
          read.push_back(*frame);
        }
      }
      ::close(fd);
    });
  }

  ~FakeBrowserHost() {
    ::shutdown(listener, SHUT_RDWR);
    ::close(listener);
    if (thread.joinable()) thread.join();
    ::unlink(path.c_str());
  }

  size_t frames_read() {
    std::lock_guard<std::mutex> lock(mutex);
    return read.size();
  }

  static inline int count = 0;
};

// The fake browser host runs in this test process: the signature check
// (ProviderLinkPeerSignedAsCmux, macOS) is the test's.
bool SignedPeer(int) { return true; }

void TheTransportRelaysBothWays() {
  constexpr int kCommands = 300;
  std::vector<std::string> frames = {"{\"t\":\"relay.attach\",\"targetId\":\"T\",\"browser\":7}"};
  for (int i = 0; i < kCommands; ++i) {
    frames.push_back(EncodeRelayCdp("T", "{\"id\":" + std::to_string(kDirectFirstRawId + i) + ",\"method\":\"X\"}"));
  }
  FakeBrowserHost browser_host("cred-1", frames);
  MainQueue main;
  std::vector<RelayFrame> got;
  int batches = 0;
  bool ended = false;
  ProviderLink link([&main](std::function<void()> task) { main.Post(std::move(task)); },
                    [&](std::vector<RelayFrame> batch) {
                      ++batches;
                      for (RelayFrame& frame : batch) got.push_back(std::move(frame));
                    },
                    [&] { ended = true; }, SignedPeer);
  ProviderLinkConfig config;
  config.socket = browser_host.path;
  config.credential = "cred-1";
  config.link_id = "L1";
  config.host_pid = ::getpid();  // the fake runs in this process
  link.Connect(config);
  Check(main.PumpUntil([&] { return got.size() == frames.size(); }), "every frame reaches the UI thread");
  Check(link.connected(), "the link is up after the ack");
  Check(batches < static_cast<int>(frames.size()), "frames that arrive together run as one batch");
  Check(!got.empty() && got[0].kind == RelayFrame::Kind::kAttach && got[0].browser == 7, "relay.attach first");
  Check(browser_host.hello.find("\"link\":\"L1\"") != std::string::npos, "relay.hello names the link cmux gave");
  link.Connect(config);
  Check(link.connected(), "the same config again keeps the link: no redial");
  for (int i = 0; i < kCommands; ++i) link.Write(EncodeRelayCdp("T", "{\"id\":" + std::to_string(i) + "}"));
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (browser_host.frames_read() < static_cast<size_t>(kCommands) && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::yield();
  }
  Check(browser_host.frames_read() == static_cast<size_t>(kCommands), "every write reaches the browser host");
  link.Close();
  Check(!ended, "a Close reports no end");
}

void TheTransportRefusesAnotherPeerAnUnsignedPeerAndAWrongCredential() {
  {
    FakeBrowserHost browser_host("cred-1", {});
    MainQueue main;
    bool ended = false;
    ProviderLink link([&main](std::function<void()> task) { main.Post(std::move(task)); },
                      [](std::vector<RelayFrame>) {}, [&] { ended = true; }, SignedPeer);
    ProviderLinkConfig config;
    config.socket = browser_host.path;
    config.credential = "cred-1";
    config.link_id = "L1";
    config.host_pid = ::getpid() + 100000;  // not this process
    config.listener_pid = ::getpid() + 100001;
    link.Connect(config);
    Check(main.PumpUntil([&] { return ended; }), "a socket held by another process ends the link");
    Check(browser_host.hello.empty(), "and the credential never left");
  }
  {
    FakeBrowserHost browser_host("cred-1", {});
    MainQueue main;
    bool ended = false;
    ProviderLink link([&main](std::function<void()> task) { main.Post(std::move(task)); },
                      [](std::vector<RelayFrame>) {}, [&] { ended = true; }, SignedPeer);
    ProviderLinkConfig config;
    config.socket = browser_host.path;
    config.credential = "wrong";
    config.link_id = "L1";
    link.Connect(config);
    Check(main.PumpUntil([&] { return ended; }), "a link the browser host does not ack ends");
    Check(!link.connected(), "and is not up");
  }
  {
    // The right pid, but code not signed as this cmux.
    FakeBrowserHost browser_host("cred-1", {});
    MainQueue main;
    bool ended = false;
    int checked = -1;
    ProviderLink link([&main](std::function<void()> task) { main.Post(std::move(task)); },
                      [](std::vector<RelayFrame>) {}, [&] { ended = true; },
                      [&checked](int fd) {
                        checked = fd;
                        return false;
                      });
    ProviderLinkConfig config;
    config.socket = browser_host.path;
    config.credential = "cred-1";
    config.link_id = "L1";
    config.host_pid = ::getpid();
    link.Connect(config);
    Check(main.PumpUntil([&] { return ended; }), "a peer not signed as cmux ends the link");
    Check(checked >= 0, "the signature check ran on the dialed socket");
    Check(browser_host.hello.empty(), "and the credential never left");
    Check(!link.connected(), "and the link is not up");
  }
}

}  // namespace

int main() {
  FramesEncodeAndDecode();
  TheOpEncodesAndDecodes();
  RelaysAPagesCommandsAndTakesItsMessages();
  TheDispatcherRelaysThroughTheLink();
  TheTransportRelaysBothWays();
  TheTransportRefusesAnotherPeerAnUnsignedPeerAndAWrongCredential();
  if (failures) {
    std::fprintf(stderr, "chromium-host-provider-link: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("chromium-host-provider-link tests: ok\n");
  return 0;
}
