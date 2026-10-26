// The remote shim (client/remote_shim.mm) against a fake host on a socket pair: calls return at
// once, the preinit replay log (latest values) goes first at every attach, the attach queue never
// drops and coalesces state ops, optional ops need the HELLO, ids are minted from 1 << 20, mirror
// values pushed before an EVENT are read in that event's callback, a post's pending keys hide
// the old value until the ack, and a bad frame ends the host. Built and run by
// scripts/cmux-next/tests/remote-shim-abi.test.sh; needs no CEF. One translation unit with the
// client, for the generated op ids (generated/remote_shim.inc also defines the exports).
#include "remote_shim.mm"

#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using cmux_host::control::Decode;
using cmux_host::control::Encode;
using cmux_host::control::EncodeFields;
using cmux_host::control::Message;
using cmux_host::control::Parse;
using cmux_host::control::TlvReader;
using cmux_host::control::TlvWriter;

int failures = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                         \
    }                                                                     \
  } while (0)

// The test's main thread queue: what cmux's MainWorkScheduler is in the app.
std::mutex queue_mutex;
std::deque<std::pair<cmux_remote_main_task_fn, void*>> queue;

void PostMain(void*, cmux_remote_main_task_fn run, void* task) {
  std::lock_guard<std::mutex> lock(queue_mutex);
  queue.emplace_back(run, task);
}

// Runs posted tasks until `done` holds or `limit` passes.
bool PumpUntil(const std::function<bool()>& done, std::chrono::milliseconds limit = std::chrono::seconds(5)) {
  const auto deadline = std::chrono::steady_clock::now() + limit;
  while (!done()) {
    std::deque<std::pair<cmux_remote_main_task_fn, void*>> tasks;
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      tasks.swap(queue);
    }
    for (auto& [run, task] : tasks) run(task);
    if (std::chrono::steady_clock::now() > deadline) return false;
    if (tasks.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

// The fake host's end: frames cmux sent, and frames to send back.
struct Host {
  int fd = -1;
  std::vector<uint8_t> buffer;
  std::deque<int> fds;

  // Reads until `count` messages arrived (or 5 s pass).
  std::vector<Message> Read(size_t count) {
    std::vector<Message> out;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (out.size() < count && std::chrono::steady_clock::now() < deadline) {
      Message message;
      size_t used = 0;
      const Parse parse = buffer.empty() ? Parse::kNeedMore : Decode(buffer.data(), buffer.size(), &fds, &message, &used);
      if (parse == Parse::kFrame) {
        buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(used));
        out.push_back(std::move(message));
        continue;
      }
      if (parse == Parse::kMalformed) break;
      pollfd p{fd, POLLIN, 0};
      if (::poll(&p, 1, 50) <= 0) continue;
      uint8_t chunk[4096];
      const ssize_t n = ::read(fd, chunk, sizeof chunk);
      if (n <= 0) break;
      buffer.insert(buffer.end(), chunk, chunk + n);
    }
    return out;
  }

  void Send(const Message& message) {
    std::vector<uint8_t> bytes;
    CHECK(Encode(message, &bytes));
    CHECK(::write(fd, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
  }
};

int AttachNew(Host* host) {
  int pair[2];
  if (::socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 0;
  host->fd = pair[1];
  host->buffer.clear();
  return cmux_remote_shim_attach(pair[0], nullptr, nullptr);
}

Message Mirror(uint16_t op, int32_t browser, const char* value) {
  TlvWriter key;
  key.I32(browser);
  TlvWriter v;
  v.Str(value);
  std::string key_bytes, value_bytes;
  EncodeFields(key.fields(), &key_bytes);
  EncodeFields(v.fields(), &value_bytes);
  TlvWriter m;
  m.I32(op);
  m.Bytes(key_bytes.data(), key_bytes.size());
  m.Bytes(value_bytes.data(), value_bytes.size());
  Message message;
  message.op = cmux_remote::kOpMirror;
  message.fields = m.Take();
  return message;
}

Message Event(int kind, int browser) {
  TlvWriter w;
  w.I32(kind);
  w.I32(browser);
  w.I32(0);
  w.I64(7);
  w.I64(8);
  w.Str("s1");
  w.Str(nullptr);
  Message message;
  message.op = cmux_remote::kOpEvent;
  message.fields = w.Take();
  return message;
}

struct Seen {
  int events = 0;
  std::string state_in_event;
  std::string s2;
  int ended = -1;
  bool scheduled = false;
  int ready = 0;
  std::vector<uint32_t> replies;
};
Seen seen;

Message Hello(const char* wire) {
  TlvWriter w;
  w.Str(wire);
  const char* exports[] = {"cmux_shim_tab_evaluate"};
  w.StrList(exports, 1);
  Message message;
  message.op = cmux_host::control::kOpHello;
  message.fields = w.Take();
  return message;
}

void OnReady(void*) {
  ++seen.ready;
}

void OnReply(void*, uint32_t token, const void* fields, size_t length) {
  std::vector<cmux_host::control::Field> decoded;
  CHECK(cmux_host::control::DecodeFields(std::string_view(static_cast<const char*>(fields), length), &decoded));
  TlvReader r(std::move(decoded));
  CHECK(r.I32() == 1 && r.ok() && r.AtEnd());
  seen.replies.push_back(token);
}

std::string NavigationState(int browser) {
  char* s = cmux_shim_tab_navigation_state(browser);
  std::string out = s ? s : "<null>";
  cmux_shim_free(s);
  return out;
}

void OnEvent(void*, int, int browser_id, int, int64_t a, int64_t b, const char*, const char* s2) {
  ++seen.events;
  CHECK(a == 7 && b == 8);
  seen.s2 = s2;
  seen.state_in_event = NavigationState(browser_id);
}

void OnSchedule(void*, int64_t) {
  seen.scheduled = true;
}

void OnEnded(void*, int reason) {
  seen.ended = reason;
}

}  // namespace

int main() {
  // ABI identity and the local exports.
  CHECK(std::strcmp(cmux_shim_abi_id(), CMUX_TEST_ABI_ID) == 0);
  char err[16] = "x";
  CHECK(cmux_shim_load("/nonexistent", err, sizeof err) == 1 && err[0] == '\0');
  CHECK(cmux_shim_prepare_application() == 1);
  CHECK(cmux_shim_password_entry_size() == static_cast<int>(sizeof(cmux_shim_password_entry)));
  cmux_shim_do_work();

  // Before attach: mints, a queued post, queued preinit ops, a mirror read that is a fault.
  CHECK(cmux_shim_tab_add(1, "https://a.test/", 0, 1) == cmux_remote::kFirstMintedBrowserID);
  CHECK(cmux_shim_tab_add(1, "https://b.test/", 1, 0) == cmux_remote::kFirstMintedBrowserID + 1);
  CHECK(cmux_shim_create_window(5, nullptr, 800, 600, "https://c.test/", nullptr) == 1);
  CHECK(cmux_shim_devtools_call(1, "Page.enable", "{}") == cmux_remote::kFirstMintedDevToolsID);
  cmux_shim_set_background_color(0xff102030u);
  CHECK(cmux_shim_page_scheme_add("docs", "/tmp", nullptr) == 1);
  // The in-process shim's own refusals: nothing is queued for them.
  CHECK(cmux_shim_page_scheme_add("cmux.settings", "/tmp", nullptr) == 0);  // reserved
  CHECK(cmux_shim_page_scheme_add("no spaces", "/tmp", nullptr) == 0);
  CHECK(cmux_shim_page_scheme_add_first_party("docs", "/tmp", nullptr) == 0);  // not reserved
  CHECK(cmux_shim_page_scheme_add_first_party_dynamic("cmux.app", "/tmp", nullptr, nullptr, "../x") == 0);
  CHECK(cmux_shim_add_native_messaging_dir("", 1) == 0);
  CHECK(cmux_shim_window_count() == 0);
  cmux_remote_shim_stats stats = {};
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.reads_unattached == 1);

  const char* switches[] = {"enable-logging", "v=1", nullptr};
  CHECK(cmux_shim_initialize("/fw", "/app", "/helper", "/cache", nullptr, 0, "en-US", nullptr, switches, nullptr,
                             &OnSchedule, &OnEvent, nullptr) == 1);
  CHECK(cmux_shim_initialize("/fw", "/app", "/helper", "/cache", nullptr, 0, nullptr, nullptr, nullptr, nullptr,
                             &OnSchedule, &OnEvent, nullptr) == 0);
  // After initialize a preinit export still goes in the replay log, so it leads INITIALIZE.
  cmux_shim_set_new_tab_page_url("cmux-page://new-tab/");

  // The attach queue never drops: past the channel's quota it counts the excess, and a state op
  // replaces its waiting predecessor.
  const int first = cmux_remote::kFirstMintedBrowserID;
  cmux_shim_set_zoom_level(first, 1.0);
  cmux_shim_set_zoom_level(first, 2.0);
  constexpr int kQueuedStops = static_cast<int>(cmux_host::control::kQuotaMessages) + 1000;
  for (int i = 0; i < kQueuedStops; ++i) cmux_shim_stop(first);
  cmux_shim_set_zoom_level(first, 3.0);
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.coalesced == 2);
  CHECK(stats.quota_excess > 0);
  CHECK(stats.unsendable == 0);
  // An optional op waits for the host's HELLO, and the posts after it keep their place.
  CHECK(cmux_shim_tab_set_frozen(first, 1) == 1);
  cmux_shim_reload(first);

  CHECK(cmux_remote_shim_attach(3, nullptr, nullptr) == 0);  // not configured
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ended = &OnEnded;
  callbacks.ready = &OnReady;
  callbacks.reply = &OnReply;
  cmux_remote_shim_configure(&callbacks);

  Host host;
  CHECK(AttachNew(&host) == 1);
  CHECK(cmux_remote_shim_attached() == 1);
  uint32_t scheme_token = 0;
  {
    // HELLO, the replay log in call order, INITIALIZE, then the posts in call order up to the
    // optional op.
    std::vector<uint16_t> want = {
        cmux_host::control::kOpHello,     cmux_remote::kOpSetBackgroundColor, cmux_remote::kOpPageSchemeAdd,
        cmux_remote::kOpSetNewTabPageUrl, cmux_remote::kOpInitialize,         cmux_remote::kOpTabAdd,
        cmux_remote::kOpTabAdd,           cmux_remote::kOpCreateWindow,       cmux_remote::kOpDevtoolsCall};
    want.insert(want.end(), kQueuedStops, cmux_remote::kOpStop);
    want.push_back(cmux_remote::kOpSetZoomLevel);
    std::vector<Message> got = host.Read(want.size());
    CHECK(got.size() == want.size());
    for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK(got[i].op == want[i]);
    if (got.size() == want.size()) {
      TlvReader zoom(got.back().fields);
      CHECK(zoom.I32() == first && zoom.F64() == 3.0 && zoom.ok() && zoom.AtEnd());
      TlvReader hello(got[0].fields);
      CHECK(hello.Str() == std::optional<std::string>(cmux_remote::kWireID));
      CHECK(hello.Str() == std::optional<std::string>(cmux_remote::kShimAbiID));
      CHECK(hello.ok() && hello.AtEnd());
      got.erase(got.begin());
      TlvReader color(got[0].fields);
      CHECK(color.U32() == 0xff102030u && color.ok() && color.AtEnd());
      CHECK(got[0].token == 0);
      scheme_token = got[1].token;  // a non-void preinit asks the host's verdict
      CHECK(scheme_token != 0);
      TlvReader url(got[2].fields);
      CHECK(url.Str() == std::optional<std::string>("cmux-page://new-tab/"));
      TlvReader init(got[3].fields);
      CHECK(init.Str() == std::optional<std::string>("/fw"));
      init.Str();
      init.Str();
      init.Str();
      CHECK(!init.Str().has_value());  // log_file NULL stays NULL
      CHECK(init.I32() == 0);
      init.Str();
      CHECK(!init.Str().has_value());
      CHECK(init.StrList() == std::vector<std::string>({"enable-logging", "v=1"}));
      CHECK(init.ok() && init.AtEnd());
      TlvReader tab(got[4].fields);
      CHECK(tab.I32() == cmux_remote::kFirstMintedBrowserID);  // the minted id goes first
      TlvReader window(got[6].fields);
      CHECK(window.I32() == cmux_remote::kFirstMintedBrowserID + 2);
      CHECK(window.I32() == 5);
    }
  }
  CHECK(!seen.scheduled);

  // The host's HELLO: ready, with the optional exports its shim defines.
  host.Send(Hello(cmux_remote::kWireID));
  CHECK(PumpUntil([] { return seen.ready == 1; }));
  CHECK(cmux_remote_shim_host_has_export("cmux_shim_tab_evaluate") == 1);
  CHECK(cmux_remote_shim_host_has_export("cmux_shim_tab_set_frozen") == 0);
  // The HELLO did not list tab_set_frozen: the queued one is refused, and the reload after it
  // goes; later calls fail at once, as a missing symbol would in process.
  {
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpReload);
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.unsupported == 1);
    CHECK(cmux_shim_tab_set_frozen(first, 0) == 0);
    cmux_remote_shim_get_stats(&stats);
    CHECK(stats.unsupported == 2);
    CHECK(stats.unsendable == 0);
  }

  // The verdict on the awaited preinit token reaches the reply callback once.
  {
    cmux_host::control::TlvWriter verdict;
    verdict.I32(1);
    Message reply;
    reply.op = cmux_remote::kOpReply;
    reply.token = scheme_token;
    reply.fields = verdict.Take();
    host.Send(reply);
    CHECK(PumpUntil([] { return !seen.replies.empty(); }));
    CHECK(seen.replies == std::vector<uint32_t>({scheme_token}));
  }

  // An async op returns at once; the token read right after it names its REPLY (task 018).
  {
    CHECK(cmux_shim_content_setting(cmux_remote::kFirstMintedBrowserID, "https://a.test/", "cookies") == 1);
    const uint32_t token = cmux_remote_shim_last_reply_token();
    CHECK(token != 0 && token != scheme_token);
    cmux_shim_reload(cmux_remote::kFirstMintedBrowserID);  // a post asks no answer: the token stays
    CHECK(cmux_remote_shim_last_reply_token() == token);
    const std::vector<Message> got = host.Read(2);
    CHECK(got.size() == 2 && got[0].op == cmux_remote::kOpContentSetting && got[0].token == token);
    cmux_host::control::TlvWriter setting;
    setting.I32(1);
    Message reply;
    reply.op = cmux_remote::kOpReply;
    reply.token = token;
    reply.fields = setting.Take();
    host.Send(reply);
    CHECK(PumpUntil([] { return seen.replies.size() == 2; }));
    CHECK(seen.replies == std::vector<uint32_t>({scheme_token, token}));

    // cmux_remote_shim_set_reply moves the replies to another sink and its ctx (CEFRemoteShim's).
    static std::vector<std::pair<void*, uint32_t>> sunk;
    int sink_ctx = 0;
    cmux_remote_shim_set_reply(&sink_ctx, [](void* ctx, uint32_t answered, const void*, size_t) {
      sunk.emplace_back(ctx, answered);
    });
    CHECK(cmux_shim_content_setting(cmux_remote::kFirstMintedBrowserID, "https://b.test/", "cookies") == 1);
    const uint32_t moved = cmux_remote_shim_last_reply_token();
    CHECK(moved != 0 && moved != token);
    const std::vector<Message> sent = host.Read(1);
    CHECK(sent.size() == 1 && sent[0].token == moved);
    reply.token = moved;
    host.Send(reply);
    CHECK(PumpUntil([] { return !sunk.empty(); }));
    CHECK(sunk.size() == 1 && sunk[0].first == &sink_ctx && sunk[0].second == moved);
    CHECK(seen.replies.size() == 2);
    cmux_remote_shim_set_reply(nullptr, &OnReply);
  }

  // A mirror value pushed before its EVENT is what the event's callback reads.
  const int browser = cmux_remote::kFirstMintedBrowserID;
  host.Send(Mirror(cmux_remote::kOpTabNavigationState, browser, "{\"index\":1}"));
  host.Send(Event(CMUX_SHIM_ADDRESS, browser));
  CHECK(PumpUntil([] { return seen.events == 1; }));
  CHECK(seen.state_in_event == "{\"index\":1}");
  CHECK(seen.s2.empty());  // a NULL string reaches the callback as ""

  // A resize fence carries this process's port name, which means nothing in the host: the
  // client refuses it as a fork without the call would and sends nothing, so the next frame
  // the host reads is go_back's.
  CHECK(cmux_shim_browser_set_resize_fence(browser, 0x1103u, 2) == 0);

  // go_back marks the navigation state pending under its token until the host's ack.
  cmux_shim_go_back(browser);
  CHECK(NavigationState(browser) == "<null>");
  CHECK(NavigationState(browser + 1) == "<null>");  // never pushed
  {
    const std::vector<Message> got = host.Read(1);
    CHECK(got.size() == 1 && got[0].op == cmux_remote::kOpGoBack && got[0].token != 0);
    if (!got.empty()) {
      Message ack;
      ack.op = cmux_remote::kOpAck;
      ack.token = got[0].token;
      host.Send(ack);
      CHECK(PumpUntil([&] { return NavigationState(browser) == "{\"index\":1}"; }));
    }
  }

  // Settings changes after initialize go now, and into the replay log for the next host.
  cmux_shim_set_new_tab_page_url("cmux-page://latest/");
  cmux_shim_set_background_color(0xff445566u);
  CHECK(cmux_shim_page_scheme_add("later", "/tmp", nullptr) == 1);
  {
    const std::vector<Message> got = host.Read(3);
    CHECK(got.size() == 3);
    if (got.size() == 3) {
      CHECK(got[0].op == cmux_remote::kOpSetNewTabPageUrl && got[0].token == 0);
      CHECK(got[1].op == cmux_remote::kOpSetBackgroundColor && got[1].token == 0);
      CHECK(got[2].op == cmux_remote::kOpPageSchemeAdd && got[2].token != 0);
    }
  }

  // A host that never reads: posts still return at once, and the geometry of a page waits
  // coalesced to one frame.
  cmux_remote_shim_get_stats(&stats);
  const uint64_t coalesced = stats.coalesced;
  const auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < 20000; ++i) cmux_shim_set_zoom_level(browser, 1.0);
  CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.coalesced > coalesced);
  CHECK(stats.pending_messages >= 1 && stats.pending_messages <= 2);  // one waiting, one maybe half written

  // A second reply to the same token answers no request: it ends the host.
  Message again;
  again.op = cmux_remote::kOpReply;
  again.token = scheme_token;
  host.Send(again);
  CHECK(PumpUntil([] { return seen.ended >= 0; }));
  CHECK(seen.ended == CMUX_REMOTE_END_MALFORMED);
  CHECK(cmux_remote_shim_attached() == 0);
  CHECK(NavigationState(browser) == "<null>");  // the cache went with the host
  cmux_remote_shim_get_stats(&stats);
  const uint64_t unsendable = stats.unsendable;
  cmux_shim_load_url(browser, "https://d.test/");
  cmux_remote_shim_get_stats(&stats);
  CHECK(stats.unsendable == unsendable + 1);
  ::close(host.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));  // the old channel's end, dropped

  // With no host, a settings change is kept for the next one, and a new scheme asks its verdict
  // there.
  cmux_shim_set_background_color(0xff778899u);
  CHECK(cmux_shim_page_scheme_add("gone", "/tmp", nullptr) == 1);

  // A restarted host gets HELLO, the replay log with the latest values (each verdict asked
  // once) and INITIALIZE, then new posts.
  Host second;
  CHECK(AttachNew(&second) == 1);
  cmux_shim_stop(browser);
  {
    const std::vector<uint16_t> want = {cmux_host::control::kOpHello,     cmux_remote::kOpSetBackgroundColor,
                                        cmux_remote::kOpPageSchemeAdd,    cmux_remote::kOpSetNewTabPageUrl,
                                        cmux_remote::kOpPageSchemeAdd,    cmux_remote::kOpPageSchemeAdd,
                                        cmux_remote::kOpInitialize,       cmux_remote::kOpStop};
    const std::vector<Message> got = second.Read(want.size());
    CHECK(got.size() == want.size());
    for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK(got[i].op == want[i]);
    if (got.size() == want.size()) {
      TlvReader color(got[1].fields);
      CHECK(color.U32() == 0xff778899u);
      CHECK(got[2].token == 0);
      TlvReader docs(got[2].fields);
      CHECK(docs.Str() == std::optional<std::string>("docs"));
      TlvReader url(got[3].fields);
      CHECK(url.Str() == std::optional<std::string>("cmux-page://latest/"));
      TlvReader later(got[4].fields);
      CHECK(later.Str() == std::optional<std::string>("later") && got[4].token == 0);
      TlvReader gone(got[5].fields);
      CHECK(gone.Str() == std::optional<std::string>("gone") && got[5].token != 0);
    }
  }
  // Its HELLO from another generation of the op table ends it.
  seen.ended = -1;
  second.Send(Hello("another-wire"));
  CHECK(PumpUntil([] { return seen.ended >= 0; }));
  CHECK(seen.ended == CMUX_REMOTE_END_MALFORMED);
  CHECK(seen.ready == 1);
  ::close(second.fd);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));

  // A detach cmux asks for is not reported back.
  Host third;
  CHECK(AttachNew(&third) == 1);
  seen.ended = -1;
  cmux_remote_shim_detach();
  CHECK(cmux_remote_shim_attached() == 0);
  PumpUntil([] { return false; }, std::chrono::milliseconds(100));
  CHECK(seen.ended == -1);
  ::close(third.fd);

  // View tokens: cmux passes the page view's token where the ABI takes a parent NSView*, and it
  // travels as is (never a pointer the client reads); NULL is 0.
  {
    cmux_remote::TlvWriter w;
    w.View(nullptr);
    w.View(reinterpret_cast<void*>(uintptr_t{7}));
    w.View(reinterpret_cast<void*>(uintptr_t{7}));
    CHECK(w.fields().size() == 3);
    if (w.fields().size() == 3) {
      CHECK(w.fields()[0].integer == 0);
      CHECK(w.fields()[1].integer == 7 && w.fields()[2].integer == 7);
    }
  }

  if (failures == 0) std::printf("remote shim: ok\n");
  return failures == 0 ? 0 : 1;
}
