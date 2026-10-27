// Checks dragging out of a hosted page on the host's side (src/host_drag.h and
// src/host_dispatch.mm, task p01-process-051) with a fake shim: the fork's
// cmux_drag_source_t is read with its size and a file or image over its bound
// is left out; DRAG_START's fields round-trip to the fork's struct, bytes with
// NULs included; cmux's watch sets and clears the host's handler (also when it
// came before initialize); a drag goes out under cmux's id; a drag the host
// cannot read or send ends at once with no operation; a malformed watch is a
// bad message. Whether a link or an image reaches Finder and a terminal is
// chromium-host-bench.py's drag-out row (fleet).
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_drag.h"

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

// The fake shim: the drag handler the dispatcher set and the drags it ended.
struct Shim {
  HostContext* host = nullptr;
  void (*fn)(void*, int, const void*) = nullptr;
  void* context = nullptr;
  int handler_sets = 0;
  std::vector<std::string> ended;
  int live = 0;
} shim;

// A fork drag over `bytes` (kept alive by the caller).
struct ForkDrag {
  std::string file;
  std::string image;
  ForkDragSource fork{};
  ForkDrag() {
    fork.size = static_cast<int>(sizeof(ForkDragSource));
    fork.allowed_operations = 1 | 2 | 16;
    fork.url = "https://example.com/cat.png";
    fork.url_title = "A cat";
    fork.text = "";
    fork.html = "<img src=\"cat.png\">";
    fork.html_base_url = "https://example.com/";
    fork.file_name = "cat.png";
    fork.file_contents_source_url = "https://example.com/cat.png";
    fork.download_metadata = "";
    fork.image_scale = 2;
    fork.cursor_offset_x = 12;
    fork.cursor_offset_y = 7;
  }
  void File(std::string bytes) {
    file = std::move(bytes);
    fork.file_contents = reinterpret_cast<const uint8_t*>(file.data());
    fork.file_contents_length = static_cast<int>(file.size());
  }
  void Image(std::string bytes) {
    image = std::move(bytes);
    fork.image_png = reinterpret_cast<const uint8_t*>(image.data());
    fork.image_png_length = static_cast<int>(image.size());
  }
};

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++shim.live;
  HostContext::OnShimEvent(shim.host, CMUX_SHIM_AFTER_CREATED, 3, request, 0, 0, "", "");
  return 1;
}
void cmux_shim_set_drag_source_handler(void (*fn)(void* context, int browser_id, const void* drag), void* context) {
  ++shim.handler_sets;
  shim.fn = fn;
  shim.context = context;
}
int cmux_shim_browser_drag_source_ended(int browser_id, double x, double y, double screen_x, double screen_y,
                                        int operation) {
  shim.ended.push_back(std::to_string(browser_id) + " " + std::to_string(static_cast<int>(x + y + screen_x + screen_y)) +
                       " op " + std::to_string(operation));
  return 1;
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

Message Watch(int32_t installed, uint32_t token = 0) {
  Writer w;
  w.I32(installed);
  return Op(kOpDragSourceWatch, token, w);
}

// A host after its hello; `initialized` also runs initialize and creates
// cmux's minted browser kMinted (Chromium's 3).
struct Fixture {
  std::vector<Message> sent;
  bool refuse_sends = false;
  Delegate delegate;
  Views views;
  HostContext host{[this](const Message& m) {
                     if (refuse_sends) return false;
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr};
  explicit Fixture(bool initialized = true) {
    shim = Shim();
    shim.host = &host;
    host.Attach();
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host.OnMessages({Op(control::kOpHello, 0, hello)});
    if (initialized) Initialize();
    sent.clear();
  }
  void Initialize() {
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
  }
  // The DRAG_STARTs sent since the last call.
  std::vector<std::pair<int32_t, DragSource>> Drags() {
    std::vector<std::pair<int32_t, DragSource>> drags;
    for (const Message& m : sent) {
      if (m.op != kOpDragStart) continue;
      int32_t browser = 0;
      DragSource drag;
      Check(DecodeDragStart(m.fields, &browser, &drag), "a DRAG_START decodes");
      drags.emplace_back(browser, std::move(drag));
    }
    sent.clear();
    return drags;
  }
};

void ReadsTheForkStruct() {
  ForkDrag f;
  f.File(std::string("\x89PNG\0\x01", 6));
  f.Image(std::string("img\0png", 7));
  DragSource d;
  Check(ReadForkDragSource(&f.fork, &d), "an API 30 struct reads");
  Check(d.allowed_operations == 19 && d.url == "https://example.com/cat.png" && d.url_title == "A cat" && d.text.empty(),
        "operations, URL, title and text");
  Check(d.html == "<img src=\"cat.png\">" && d.html_base_url == "https://example.com/", "HTML and its base URL");
  Check(d.file_contents == std::string("\x89PNG\0\x01", 6) && d.file_name == "cat.png" &&
            d.file_contents_source_url == "https://example.com/cat.png",
        "the file's bytes, NULs included, its name and its URL");
  Check(d.image_png == std::string("img\0png", 7) && d.image_scale == 2 && d.cursor_offset_x == 12 && d.cursor_offset_y == 7,
        "the drag image, its scale and the pointer's offset");

  ForkDrag absent;
  absent.fork.url = nullptr;
  absent.fork.file_contents_length = 5;  // a length with no bytes
  absent.fork.image_scale = 0;
  Check(ReadForkDragSource(&absent.fork, &d) && d.url.empty() && d.file_contents.empty() && d.image_png.empty() &&
            d.image_scale == 1,
        "a NULL string reads empty, a length with no bytes reads none, a bad scale reads 1");

  ForkDrag big;
  big.File(std::string(kMaxDragFileBytes + 1, 'f'));
  big.Image(std::string(kMaxDragImageBytes + 1, 'i'));
  Check(ReadForkDragSource(&big.fork, &d) && d.file_contents.empty() && d.image_png.empty() && !d.url.empty(),
        "a file and an image over their bounds are left out; the URL stays");

  ForkDrag old;
  old.fork.size = static_cast<int>(sizeof(ForkDragSource)) - 8;
  DragSource untouched;
  untouched.url = "keep";
  Check(!ReadForkDragSource(&old.fork, &untouched) && untouched.url == "keep", "a struct older than API 30 is refused");
  Check(!ReadForkDragSource(nullptr, &untouched), "no drag is refused");
}

void RoundTripsTheWire() {
  ForkDrag f;
  f.File(std::string(70000, '\0') + "tail");  // past 64 KiB: the channel puts it in shared memory
  f.Image("png");
  f.fork.text = "caf\xc3\xa9 \xff";  // not UTF-8: travels as bytes
  DragSource d;
  Check(ReadForkDragSource(&f.fork, &d), "reads");
  int32_t browser = 0;
  DragSource back;
  Check(DecodeDragStart(EncodeDragStart(kMinted, d), &browser, &back) && browser == kMinted && back == d,
        "DRAG_START round-trips every field");
  const ForkDragSource view = ForkViewOf(back);
  Check(view.size == static_cast<int>(sizeof(ForkDragSource)) && view.allowed_operations == 19, "the view's size and mask");
  Check(std::strcmp(view.url, "https://example.com/cat.png") == 0 && std::strcmp(view.text, "caf\xc3\xa9 \xff") == 0,
        "the view's strings");
  Check(view.file_contents_length == 70004 && std::memcmp(view.file_contents + 70000, "tail", 4) == 0,
        "the view's file bytes");
  Check(view.image_png_length == 3 && view.image_scale == 2 && view.cursor_offset_y == 7, "the view's image");
  DragSource read_back;
  Check(ReadForkDragSource(&view, &read_back) && read_back == back, "the view reads as the drag it came from");
  DragSource none;
  const ForkDragSource empty = ForkViewOf(none);
  Check(empty.file_contents == nullptr && empty.image_png == nullptr && empty.url != nullptr && *empty.url == '\0',
        "no bytes are NULL, no string is \"\" (the fork's contract)");

  std::vector<control::Field> fields = EncodeDragStart(1, d);
  fields.pop_back();
  Check(!DecodeDragStart(fields, &browser, &back), "a missing field is refused");
  fields = EncodeDragStart(1, d);
  fields.push_back(control::Field::I32(0, 1));
  Check(!DecodeDragStart(fields, &browser, &back), "an extra field is refused");
  DragSource scaled = d;
  scaled.image_scale = -1;
  Check(!DecodeDragStart(EncodeDragStart(1, scaled), &browser, &back), "a bad scale is refused");
  DragSource huge;
  huge.image_png.assign(kMaxDragImageBytes + 1, 'i');
  Check(!DecodeDragStart(EncodeDragStart(1, huge), &browser, &back), "an image over its bound is refused");
}

void WatchSetsTheHandler() {
  Fixture t;
  t.host.OnMessages({Watch(1, 7)});
  Check(shim.fn == &HostContext::OnDragSource && shim.context == &t.host, "the watch sets the host's handler");
  Check(t.sent.size() == 1 && t.sent[0].op == kOpAck && t.sent[0].token == 7, "a watch with a token is acked");
  t.sent.clear();
  t.host.OnMessages({Watch(0)});
  Check(shim.fn == nullptr && shim.context == nullptr && shim.handler_sets == 2, "watch 0 restores Chromium's session");
  Check(t.sent.empty(), "a watch with no token sends nothing");
  Check(t.delegate.calls == std::vector<std::string>({"initialize"}), "no bad message");

  Fixture early(false);
  early.host.OnMessages({Watch(1)});
  Check(shim.handler_sets == 0, "a watch before initialize waits");
  early.Initialize();
  Check(shim.fn == &HostContext::OnDragSource && shim.handler_sets == 1, "and applies once initialize returned");

  Fixture bad;
  bad.host.OnMessages({Watch(2)});
  Check(bad.delegate.calls.back() == "bad a malformed drag source watch", "a watch of 2 is a bad message");
  Fixture missing;
  missing.host.OnMessages({Op(kOpDragSourceWatch, 0, Writer())});
  Check(missing.delegate.calls.back() == "bad a malformed drag source watch", "a watch with no field is a bad message");
}

void DragGoesToCmux() {
  Fixture t;
  t.host.OnMessages({Watch(1)});
  t.sent.clear();
  ForkDrag f;
  f.Image("png");
  shim.fn(shim.context, 3, &f.fork);
  std::vector<std::pair<int32_t, DragSource>> drags = t.Drags();
  Check(drags.size() == 1 && drags[0].first == kMinted, "a drag goes out under cmux's id");
  Check(drags.size() == 1 && drags[0].second.url == "https://example.com/cat.png" && drags[0].second.image_png == "png",
        "with its data");
  Check(shim.ended.empty(), "cmux ends a drag it got");

  ForkDrag old;
  old.fork.size = 8;
  shim.fn(shim.context, 3, &old.fork);
  Check(t.Drags().empty() && shim.ended == std::vector<std::string>({"3 0 op 0"}),
        "a drag the host cannot read ends at once, with no operation, under Chromium's id");

  shim.ended.clear();
  t.refuse_sends = true;
  shim.fn(shim.context, 3, &f.fork);
  Check(shim.ended == std::vector<std::string>({"3 0 op 0"}), "a drag the channel refused ends at once");
}

}  // namespace

int main() {
  ReadsTheForkStruct();
  RoundTripsTheWire();
  WatchSetsTheHandler();
  DragGoesToCmux();
  if (failures) {
    std::fprintf(stderr, "host_drag_test: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("host_drag_test: ok\n");
  return 0;
}
