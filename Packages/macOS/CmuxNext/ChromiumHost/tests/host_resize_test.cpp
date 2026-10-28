// Checks a hosted page's resize and its fence on the host's side
// (src/host_resize.h), alone and through the dispatcher
// (src/host_dispatch.mm) with a fake shim and a fake inbox: the op's fields
// round-trip and a malformed op is refused; a fence is taken by its seq, the
// fences of older seqs and those past kMaxPendingFences are released; the
// fork gets the fence before the page view's frame changes, under the
// browser's Chromium id, with a deadline of one display frame at most; the
// host's own right is always released; a fenced op is answered with whether
// the fork took the fence, an unfenced one is not answered; an op that comes
// before initialize waits for it; a view's size stays after its browsers
// close, for the next browser on it, and the sizes kept are bounded without
// ending the host. The Mach transport itself (SendFence and the checked-in
// inbox) is macOS only: cef-resize-sync-bench.py --modes host measures it on
// the fleet.
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_resize.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;
using cmux_host::control::Message;
using Writer = cmux_host::control::TlvWriter;

constexpr int32_t kMinted = 1 << 20;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// Fences cmux sent and the rights the host released, in order.
struct FakeInbox : FenceInbox {
  std::vector<Fence> waiting;
  std::vector<uint32_t> released;
  std::vector<std::string>* log = nullptr;
  std::vector<Fence> Drain() override {
    std::vector<Fence> out;
    out.swap(waiting);
    return out;
  }
  void Release(uint32_t right) override {
    released.push_back(right);
    if (log) log->push_back("release " + std::to_string(right));
  }
};

// The fake shim: the joins the dispatcher made, and the browser it creates.
struct Shim {
  HostContext* host = nullptr;
  std::vector<std::string>* log = nullptr;
  int live = 0;
  int join_result = 1;
} shim;

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 32; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++shim.live;
  HostContext::OnShimEvent(shim.host, CMUX_SHIM_AFTER_CREATED, 3, request, 0, 0, "", "");
  return 1;
}
int cmux_shim_browser_set_resize_fence(int browser_id, unsigned int fence_port, unsigned int deadline_frames) {
  if (shim.log) {
    shim.log->push_back("join " + std::to_string(browser_id) + " " + std::to_string(fence_port) + " " +
                        std::to_string(deadline_frames));
  }
  return shim.join_result;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return shim.live; }
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
  std::vector<std::string>* log = nullptr;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const PageGeometry&) override {}
  void Resize(uint64_t token, int32_t width, int32_t height) override {
    if (log) log->push_back("resize " + std::to_string(token) + " " + std::to_string(width) + "x" + std::to_string(height));
  }
};

Message Op(uint16_t op, uint32_t token, const std::vector<control::Field>& fields) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = fields;
  return m;
}

std::vector<control::Field> Fields(const PageResize& resize) {
  Writer w;
  WritePageResize(resize, &w);
  return w.Take();
}

PageResize Resize(uint64_t view, int32_t browser, int32_t width, int32_t height, uint64_t seq, uint32_t frames) {
  PageResize resize;
  resize.view = view;
  resize.browser = browser;
  resize.width = width;
  resize.height = height;
  resize.fence_seq = seq;
  resize.deadline_frames = frames;
  return resize;
}

void FieldsRoundTrip() {
  const PageResize sent = Resize(9, kMinted, 640, 480, 7, 2);
  const std::optional<PageResize> got = DecodePageResize(Fields(sent));
  Check(got && got->view == 9 && got->browser == kMinted && got->width == 640 && got->height == 480 &&
            got->fence_seq == 7 && got->deadline_frames == 2,
        "a page resize round-trips");
  Check(!DecodePageResize(Fields(Resize(0, 1, 10, 10, 0, 1))), "view token 0 is refused");
  Check(!DecodePageResize(Fields(Resize(9, 1, 0, 10, 0, 1))), "a width under 1 point is refused");
  Check(!DecodePageResize(Fields(Resize(9, 1, 10, 40000, 0, 1))), "a height over 32767 is refused");
  std::vector<control::Field> extra = Fields(sent);
  extra.push_back(control::Field::I32(control::kTagValue, 1));
  Check(!DecodePageResize(extra), "an extra field is refused");
  std::vector<control::Field> short_op = Fields(sent);
  short_op.pop_back();
  Check(!DecodePageResize(short_op), "a missing field is refused");
  Writer negative;
  negative.ViewToken(9);
  for (int32_t v : {1, 10, 10}) negative.I32(v);
  negative.I64(0);
  negative.I32(-1);
  Check(!DecodePageResize(negative.Take()), "a negative deadline is refused");
}

void BookTakesBySeq() {
  FakeInbox inbox;
  {
    FenceBook book(&inbox);
    inbox.waiting = {{1, 101}, {2, 102}, {4, 104}};
    Check(book.Take(2) == 102, "seq 2's right");
    Check(inbox.released == std::vector<uint32_t>({101}), "seq 1's op will not come: its right is released");
    Check(book.Take(3) == 0 && book.pending() == 1, "no fence for seq 3; seq 4 waits for its op");
    Check(book.Take(0) == 0, "seq 0 has no fence");
    inbox.waiting = {{5, 105}};
    Check(book.Take(4) == 104 && book.pending() == 1, "seq 4 then, with 5 still waiting");
  }
  Check(inbox.released == std::vector<uint32_t>({101, 105}), "the book releases what waits when it goes");

  FakeInbox flood;
  FenceBook book(&flood);
  for (uint64_t seq = 1; seq <= kMaxPendingFences + 3; ++seq) flood.waiting.push_back({seq, static_cast<uint32_t>(seq)});
  Check(book.Take(kMaxPendingFences + 3) == kMaxPendingFences + 3, "the newest fence of a flood");
  Check(flood.released.size() == kMaxPendingFences + 2 && book.dropped() == kMaxPendingFences + 2,
        "the rest are released, never more than kMaxPendingFences kept");
  FenceBook none(nullptr);
  Check(none.Take(1) == 0, "no inbox: no fence");
}

void JoinsBeforeTheFrameChange() {
  std::vector<std::string> log;
  FakeInbox inbox;
  inbox.log = &log;
  PageResizes resizes(&inbox, [&log](int browser, uint32_t right, uint32_t frames) {
    log.push_back("join " + std::to_string(browser) + " " + std::to_string(right) + " " + std::to_string(frames));
    return 1;
  });
  inbox.waiting = {{1, 201}};
  Check(resizes.Apply(Resize(9, 1, 10, 10, 1, 5), 3, [&log] { log.push_back("frame"); }), "the fork took the fence");
  Check(log == std::vector<std::string>({"join 3 201 1", "release 201", "frame"}),
        "join (deadline at most one frame), the host's right released, then the frame change");
  log.clear();
  Check(!resizes.Apply(Resize(9, 1, 10, 10, 2, 0), 3, [&log] { log.push_back("frame"); }), "no fence for seq 2");
  Check(log == std::vector<std::string>({"frame"}), "the frame still changes");
  log.clear();
  inbox.waiting = {{3, 203}};
  Check(!resizes.Apply(Resize(9, 1, 10, 10, 3, 1), 0, [&log] { log.push_back("frame"); }), "a browser not open here");
  Check(log == std::vector<std::string>({"release 203", "frame"}), "its fence is released, not joined");
  log.clear();
  Check(!resizes.Apply(Resize(9, 1, 10, 10, 0, 1), 3, [&log] { log.push_back("frame"); }), "an unfenced resize");
  Check(log == std::vector<std::string>({"frame"}), "takes nothing from the inbox");
  const PageResizes::Stats& stats = resizes.stats();
  Check(stats.resizes == 4 && stats.fenced == 3 && stats.joined == 1 && stats.missing == 1, "the counters");
}

// The dispatcher, initialized, with one browser (cmux's kMinted, Chromium's
// 3) in page view 9.
struct Fixture {
  std::vector<Message> sent;
  std::vector<std::string> log;
  Delegate delegate;
  Views views;
  FakeInbox inbox;
  PageResizes resizes{&inbox, &cmux_shim_browser_set_resize_fence};
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr, nullptr};
  explicit Fixture(bool initialize = true) {
    shim = Shim();
    shim.host = &host;
    shim.log = &log;
    views.log = &log;
    inbox.log = &log;
    host.SetPageResizes(&resizes);
    host.Attach();
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host.OnMessages({Op(control::kOpHello, 0, hello.Take())});
    if (initialize) Initialize();
  }
  void Initialize() {
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host.OnMessages({Op(kOpInitialize, 1, init.Take())});
    host.Resume();
    Writer create;
    create.I32(kMinted);
    create.I32(42);
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host.OnMessages({Op(kOpCreateWindow, 2, create.Take())});
    sent.clear();
  }
  // cmux's browser `minted` in page view `view`; the fake shim makes it
  // Chromium's browser 3.
  void Create(int32_t minted, uint64_t view) {
    Writer create;
    create.I32(minted);
    create.I32(42);
    create.ViewToken(view);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host.OnMessages({Op(kOpCreateWindow, 0, create.Take())});
  }
  // Chromium's browser 3 closes.
  void Close() {
    shim.live = 0;
    HostContext::OnShimEvent(&host, CMUX_SHIM_BEFORE_CLOSE, 3, 0, 0, 0, "", "");
  }
  // Replies sent since the last call, as "token = result".
  std::vector<std::string> Replies() {
    std::vector<std::string> out;
    for (const Message& m : sent) {
      if (m.op != kOpReply) continue;
      control::TlvReader r(m.fields);
      const int32_t result = r.I32();
      out.push_back(std::to_string(m.token) + (r.ok() && r.AtEnd() ? " = " + std::to_string(result) : " ?"));
    }
    sent.clear();
    return out;
  }
};

void DispatchesThroughTheHost() {
  Fixture f;
  f.inbox.waiting = {{1, 301}};
  f.host.OnMessages({Op(kOpPageResize, 5, Fields(Resize(9, kMinted, 640, 480, 1, 1)))});
  Check(f.log == std::vector<std::string>({"join 3 301 1", "release 301", "resize 9 640x480"}),
        "the fork joins Chromium's browser 3 to the fence, then view 9 is resized");
  Check(f.Replies() == std::vector<std::string>({"5 = 1"}), "a fenced resize is answered: joined");
  f.log.clear();

  f.host.OnMessages({Op(kOpPageResize, 0, Fields(Resize(9, kMinted, 700, 480, 0, 1)))});
  Check(f.log == std::vector<std::string>({"resize 9 700x480"}) && f.Replies().empty(),
        "an unfenced resize changes the frame and is not answered");
  f.log.clear();

  shim.join_result = 0;
  f.inbox.waiting = {{2, 302}};
  f.host.OnMessages({Op(kOpPageResize, 6, Fields(Resize(9, kMinted, 720, 480, 2, 1)))});
  Check(f.Replies() == std::vector<std::string>({"6 = 0"}), "a fork that did not take the fence: answered 0");
  Check(f.inbox.released.back() == 302, "and the host's right is released all the same");
  f.log.clear();

  f.host.OnMessages({Op(kOpPageResize, 7, Fields(Resize(77, kMinted, 720, 480, 3, 1)))});
  Check(f.log.empty() && f.Replies() == std::vector<std::string>({"7 = 0"}),
        "a view not open yet is not made, its fence missing");
  Writer create;
  create.I32(kMinted + 1);
  create.I32(43);
  create.ViewToken(77);
  create.I32(800);
  create.I32(600);
  create.Str("https://b/");
  create.Str(nullptr);
  f.host.OnMessages({Op(kOpCreateWindow, 8, create.Take())});
  Check(f.log == std::vector<std::string>({"resize 77 720x480"}), "the op that opens it gives it the last size sent");
  f.sent.clear();
  f.log.clear();
  Check(f.delegate.calls == std::vector<std::string>({"initialize"}), "no bad message so far");

  Writer bad;
  bad.I32(1);
  f.host.OnMessages({Op(kOpPageResize, 0, bad.Take())});
  Check(f.delegate.calls == std::vector<std::string>({"initialize", "bad a malformed page resize"}),
        "a malformed resize ends the host");
}

void WaitsForInitialize() {
  Fixture f(false);
  f.host.OnMessages({Op(kOpPageResize, 0, Fields(Resize(9, kMinted, 640, 480, 0, 1)))});
  Check(f.log.empty() && f.delegate.calls.empty(), "a resize before initialize waits");
  f.Initialize();
  Check(f.log == std::vector<std::string>({"resize 9 640x480"}) && f.delegate.calls == std::vector<std::string>({"initialize"}),
        "and applies after it: create_window opens view 9 at that size");
}

// cmux keeps a page view token for its pane while the pane's browsers come
// and go, and sends a size only when it changes: the size a view had stays for
// the next browser opened on it.
void AReopenedViewTakesItsLastSize() {
  Fixture f;
  f.host.OnMessages({Op(kOpPageResize, 0, Fields(Resize(9, kMinted, 640, 480, 0, 1)))});
  f.Close();
  f.log.clear();
  f.Create(kMinted + 1, 9);
  Check(f.log == std::vector<std::string>({"resize 9 640x480"}),
        "the view's only browser closed, a new one on it: its window opens at the last size");
  Check(f.delegate.calls == std::vector<std::string>({"initialize", "closed"}), "no bad message");
}

// Sizes of views that are never opened, or closed, take no more room than
// kMaxSizedViews (2 * 4096, host_dispatch.mm), and a resize past it is never a
// bad message: the least recently resized closed view's size goes first, an
// open view's never.
void ManySizedViewsStayBoundedAndEndNoHost() {
  Fixture f;
  f.host.OnMessages({Op(kOpPageResize, 0, Fields(Resize(9, kMinted, 640, 480, 0, 1)))});
  f.log.clear();
  constexpr uint64_t kFirst = 1000;
  constexpr uint64_t kCount = 2 * 4096 + 16;
  for (uint64_t view = kFirst; view < kFirst + kCount; ++view) {
    f.host.OnMessages({Op(kOpPageResize, 0, Fields(Resize(view, kMinted, 100, 100, 0, 1)))});
  }
  Check(f.delegate.calls == std::vector<std::string>({"initialize"}), "valid resizes past the bound end no host");
  Check(f.log.empty(), "views never opened are not made");
  f.Close();
  f.Create(kMinted + 1, kFirst);
  Check(f.log.empty(), "the oldest closed view's size went");
  f.Close();
  f.Create(kMinted + 2, kFirst + kCount - 1);
  Check(f.log == std::vector<std::string>({"resize " + std::to_string(kFirst + kCount - 1) + " 100x100"}),
        "the newest stays");
  f.Close();
  f.log.clear();
  f.Create(kMinted + 3, 9);
  Check(f.log == std::vector<std::string>({"resize 9 640x480"}), "view 9, open through the flood, kept its size");
}

}  // namespace

int main() {
  FieldsRoundTrip();
  BookTakesBySeq();
  JoinsBeforeTheFrameChange();
  DispatchesThroughTheHost();
  WaitsForInitialize();
  AReopenedViewTakesItsLastSize();
  ManySizedViewsStayBoundedAndEndNoHost();
  if (failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("host_resize_test: ok\n");
  return 0;
}
