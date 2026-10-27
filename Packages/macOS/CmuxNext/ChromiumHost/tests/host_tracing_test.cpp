// Checks the Chromium Host's TRACE_START and TRACE_STOP (src/host_tracing.h,
// task p09-observability-104) alone and through the dispatcher
// (src/host_dispatch.mm) with a fake shim: the ops round-trip and refuse a bad
// version or extra fields; a start begins the ring's recording and Chromium's
// tracing, a stop ends both and answers with the path Chromium reported; each
// Chromium answer goes back once, through the main-thread post, also when
// Chromium answers on another thread; a refused begin or end is answered at
// once; the HELLO lists kTracingHelloName only with tracing; a host without
// it answers both ops as refused; cef.create_browser and the browser count
// reach the trace marks (HostTraceMarks).
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_tracing.h"

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

// The host's main-thread queue: the test runs it.
std::deque<std::function<void()>> main_tasks;
void PostMain(std::function<void()> task) { main_tasks.push_back(std::move(task)); }
void RunMain() {
  while (!main_tasks.empty()) {
    auto task = std::move(main_tasks.front());
    main_tasks.pop_front();
    task();
  }
}

// The fake shim's tracing calls.
struct Chromium {
  int begins = 0, ends = 0;
  std::string categories, path;
  HostTracing::StartedFn started = nullptr;
  HostTracing::WrittenFn written = nullptr;
  void* ctx = nullptr;
  int refuse = 0;  // the calls' return when not 1
} chromium;

int Begin(const char* categories, HostTracing::StartedFn started, void* ctx) {
  ++chromium.begins;
  chromium.categories = categories ? categories : "<null>";
  if (chromium.refuse) return 0;
  chromium.started = started;
  chromium.ctx = ctx;
  return 1;
}

int End(const char* path, HostTracing::WrittenFn written, void* ctx) {
  ++chromium.ends;
  chromium.path = path ? path : "<null>";
  if (chromium.refuse) return 0;
  chromium.written = written;
  chromium.ctx = ctx;
  return 1;
}

struct Recorder : TraceRecorder {
  bool recording = false;
  uint64_t categories = 0;
  bool StartRecording(uint64_t c) override {
    if (recording) return false;
    recording = true;
    categories = c;
    return true;
  }
  bool StopRecording() override {
    if (!recording) return false;
    recording = false;
    return true;
  }
};

struct Answer {
  uint32_t token;
  std::vector<control::Field> fields;
};

// The input flow ids both sides derive (ChromiumHostTraceFilesTests checks the same three in Swift).
void InputFlowsAreGolden() {
  Check(InputFlowOf(1234, 5'000'000'000ull) == 0x66319fa340c4cc97ull, "the flow of pid 1234, t0 5 s");
  Check(InputFlowOf(0xffffffffu, 1) == 0x4fa8e9bd8fd663a7ull, "the flow of the largest pid, t0 1 ns");
  Check(InputFlowOf(1234, 0) == 0, "no event time: no flow");
  Check((InputFlowOf(7, 99) >> 62) == 1, "bit 62 set, bit 63 clear");
}

void RoundTrips() {
  TraceStart start;
  start.ring_categories = kTraceRecordingCategories;
  start.chromium_categories = "toplevel,cc";
  Writer w;
  WriteTraceStart(start, &w);
  Check(DecodeTraceStart(w.fields()) == start, "TRACE_START round-trips");
  TraceStart none;
  Writer n;
  WriteTraceStart(none, &n);
  Check(DecodeTraceStart(n.fields()) == none && !DecodeTraceStart(n.fields())->chromium_categories,
        "a start with no Chromium categories asks for no Chromium tracing");
  TraceStop stop;
  stop.ring = true;
  stop.chromium_path = "/tmp/chromium.trace.json";
  Writer s;
  WriteTraceStop(stop, &s);
  Check(DecodeTraceStop(s.fields()) == stop, "TRACE_STOP round-trips");

  Writer extra;
  WriteTraceStart(start, &extra);
  extra.I32(1);
  Check(!DecodeTraceStart(extra.fields()), "version 1 with more fields is malformed");
  Writer later;
  later.I32(2);
  later.I64(1);
  later.Str(nullptr);
  later.I32(7);
  Check(DecodeTraceStart(later.fields()).has_value(), "a later version's appended fields are left");
  Writer zero;
  zero.I32(0);
  zero.I64(0);
  zero.Str(nullptr);
  Check(!DecodeTraceStart(zero.fields()), "version 0 is malformed");
  Writer bad_ring;
  bad_ring.I32(1);
  bad_ring.I32(2);
  bad_ring.Str(nullptr);
  Check(!DecodeTraceStop(bad_ring.fields()), "a ring flag other than 0 or 1 is malformed");
}

void StartsAndStopsBoth() {
  chromium = Chromium();
  Recorder recorder;
  std::vector<Answer> answers;
  HostTracing tracing(&Begin, &End, &recorder,
                      [&answers](uint32_t token, const Writer& reply) { answers.push_back({token, reply.fields()}); },
                      &PostMain);
  Check(tracing.available(), "a shim with both calls traces");

  TraceStart start;
  start.ring_categories = kTraceRecordingCategories;
  start.chromium_categories = "toplevel";
  Writer w;
  WriteTraceStart(start, &w);
  Check(tracing.Start(7, w.fields()), "a start is well formed");
  Check(recorder.recording && recorder.categories == kTraceRecordingCategories, "the ring records the categories");
  Check(chromium.begins == 1 && chromium.categories == "toplevel", "Chromium begins with the categories");
  Check(answers.empty(), "no answer before Chromium's");
  // Chromium answers on another thread (a failure while CEF shuts down): the answer still goes out on main.
  std::thread([] { chromium.started(chromium.ctx, 1); }).join();
  Check(answers.empty(), "the answer waits for the main thread");
  RunMain();
  Check(answers.size() == 1 && answers[0].token == 7, "one answer to the start's token");
  if (answers.size() == 1) {
    const auto answer = DecodeTraceStartAnswer(answers[0].fields);
    Check(answer && answer->ring && answer->chromium, "the start answers ring and Chromium");
  }

  TraceStop stop;
  stop.ring = true;
  stop.chromium_path = "/tmp/c.trace.json";
  Writer s;
  WriteTraceStop(stop, &s);
  Check(tracing.Stop(8, s.fields()), "a stop is well formed");
  Check(!recorder.recording, "the ring stops");
  Check(chromium.ends == 1 && chromium.path == "/tmp/c.trace.json", "Chromium ends into the path");
  chromium.written(chromium.ctx, "/tmp/c.trace.json");
  RunMain();
  Check(answers.size() == 2 && answers[1].token == 8, "one answer to the stop's token");
  if (answers.size() == 2) {
    const auto answer = DecodeTraceStopAnswer(answers[1].fields);
    Check(answer && answer->ring && answer->path == std::optional<std::string>("/tmp/c.trace.json"),
          "the stop answers the ring and the path Chromium wrote");
  }
}

void RefusalsAnswerAtOnce() {
  chromium = Chromium();
  chromium.refuse = 1;
  Recorder recorder;
  std::vector<Answer> answers;
  HostTracing tracing(&Begin, &End, &recorder,
                      [&answers](uint32_t token, const Writer& reply) { answers.push_back({token, reply.fields()}); },
                      &PostMain);
  TraceStart start;
  start.chromium_categories = "";
  Writer w;
  WriteTraceStart(start, &w);
  tracing.Start(3, w.fields());
  Check(answers.size() == 1 && main_tasks.empty(), "a begin Chromium refused is answered in the op's turn");
  if (!answers.empty()) {
    const auto answer = DecodeTraceStartAnswer(answers[0].fields);
    Check(answer && !answer->ring && !answer->chromium, "no categories: the ring does not record; Chromium refused");
  }
  Check(chromium.categories.empty(), "an empty filter is CEF's default, not no tracing");

  TraceStop stop;
  stop.ring = true;
  Writer s;
  WriteTraceStop(stop, &s);
  tracing.Stop(4, s.fields());
  Check(chromium.ends == 0, "no path: Chromium is not asked");
  Check(answers.size() == 2, "the stop is answered at once");
  if (answers.size() == 2) {
    const auto answer = DecodeTraceStopAnswer(answers[1].fields);
    Check(answer && !answer->ring && !answer->path, "nothing recorded, nothing written");
  }
}

// The fake shim's browsers.
HostContext* fake_host = nullptr;
int fake_live = 0;

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++fake_live;
  HostContext::OnShimEvent(fake_host, CMUX_SHIM_AFTER_CREATED, kChromiumBrowser, request, 0, 0, "", "");
  return 1;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return fake_live; }
}

namespace {

struct Delegate : HostDelegate {
  std::vector<std::string> calls;
  void Initialize(InitializeRequest) override { calls.push_back("initialize"); }
  void Quit() override { calls.push_back("quit"); }
  void BrowserClosed() override { calls.push_back("closed"); }
  void BadMessage(const std::string& what) override { calls.push_back("bad " + what); }
};

struct Views : PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const PageGeometry&) override {}
};

struct Marks : HostTraceMarks {
  std::vector<std::string> calls;
  void CreateBegan(int32_t minted) override { calls.push_back("began " + std::to_string(minted)); }
  void Created(int32_t minted) override { calls.push_back("created " + std::to_string(minted)); }
  void BrowserCount(size_t count) override { calls.push_back("count " + std::to_string(count)); }
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
  Marks marks;
  Recorder recorder;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr};
  HostTracing tracing{&Begin, &End, &recorder, [this](uint32_t token, const Writer& reply) { host.Reply(token, reply); },
                      &PostMain};
  std::vector<std::string> hello_exports;

  explicit Fixture(bool traces) {
    chromium = Chromium();
    fake_host = &host;
    fake_live = 0;
    if (traces) host.SetTracing(&tracing);
    host.SetTraceMarks(&marks);
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
  }

  bool Listed() const {
    for (const std::string& name : hello_exports) {
      if (name == kTracingHelloName) return true;
    }
    return false;
  }

  // The REPLY frames sent since the last call.
  std::vector<Message> Replies() {
    std::vector<Message> out;
    for (const Message& m : sent) {
      if (m.op == kOpReply) out.push_back(m);
    }
    sent.clear();
    return out;
  }
};

void DispatchesTheOps() {
  Fixture fixture(true);
  Check(fixture.Listed(), "the HELLO lists kTracingHelloName with tracing");
  TraceStart start;
  start.ring_categories = kTraceRecordingCategories;
  start.chromium_categories = "toplevel";
  Writer w;
  WriteTraceStart(start, &w);
  // Before initialize returned, the op waits: Chromium cannot trace yet.
  fixture.host.OnMessages({Op(kOpTraceStart, 11, w)});
  Check(chromium.begins == 0, "a start before initialize waits");
  fixture.host.Resume();
  Check(chromium.begins == 1 && fixture.recorder.recording, "the waiting start runs once initialize returned");
  chromium.started(chromium.ctx, 1);
  RunMain();
  std::vector<Message> replies = fixture.Replies();
  Check(replies.size() == 1 && replies[0].token == 11 && replies[0].reply, "one REPLY to the start");

  TraceStop stop;
  stop.ring = true;
  stop.chromium_path = "/tmp/x.json";
  Writer s;
  WriteTraceStop(stop, &s);
  fixture.host.OnMessages({Op(kOpTraceStop, 12, s)});
  chromium.written(chromium.ctx, nullptr);
  RunMain();
  replies = fixture.Replies();
  Check(replies.size() == 1 && replies[0].token == 12, "one REPLY to the stop");
  if (replies.size() == 1) {
    const auto answer = DecodeTraceStopAnswer(replies[0].fields);
    Check(answer && answer->ring && !answer->path, "Chromium wrote nothing: no path");
  }

  Writer bad;
  bad.I32(1);
  fixture.host.OnMessages({Op(kOpTraceStart, 13, bad)});
  Check(!fixture.delegate.calls.empty() && fixture.delegate.calls.back() == "bad a malformed trace op",
        "a malformed trace op is a bad message");
}

void AnswersRefusedWithoutTracing() {
  Fixture fixture(false);
  Check(!fixture.Listed(), "no tracing: the HELLO does not list it");
  fixture.host.Resume();
  fixture.sent.clear();
  TraceStart start;
  start.chromium_categories = "toplevel";
  Writer w;
  WriteTraceStart(start, &w);
  fixture.host.OnMessages({Op(kOpTraceStart, 21, w)});
  const std::vector<Message> replies = fixture.Replies();
  Check(replies.size() == 1 && replies[0].token == 21, "the start is answered");
  if (replies.size() == 1) {
    const auto answer = DecodeTraceStartAnswer(replies[0].fields);
    Check(answer && !answer->ring && !answer->chromium, "as refused");
  }
  Check(chromium.begins == 0, "nothing reaches Chromium");
}

void MarksBrowserCreations() {
  Fixture fixture(true);
  fixture.host.Resume();
  Writer create;
  create.I32(kMinted);
  create.I32(42);
  create.ViewToken(9);
  create.I32(800);
  create.I32(600);
  create.Str("https://a/");
  create.Str(nullptr);
  fixture.host.OnMessages({Op(kOpCreateWindow, 2, create)});
  const std::vector<std::string> expected = {"began " + std::to_string(kMinted), "created " + std::to_string(kMinted),
                                             "count 1"};
  Check(fixture.marks.calls == expected, "create_window: began, then created at AFTER_CREATED, then the count");
}

}  // namespace

int main() {
  InputFlowsAreGolden();
  RoundTrips();
  StartsAndStopsBoth();
  RefusalsAnswerAtOnce();
  DispatchesTheOps();
  AnswersRefusedWithoutTracing();
  MarksBrowserCreations();
  if (failures) {
    std::fprintf(stderr, "chromium-host-tracing: %d failures\n", failures);
    return 1;
  }
  std::printf("chromium-host-tracing tests: ok\n");
  return 0;
}
