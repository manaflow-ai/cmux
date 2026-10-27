// Checks printing a hosted page to PDF (src/host_print.h, task p01-process-065):
//   - kOpPrintToPdf's fields round-trip and a malformed op is refused (and ends the host);
//   - the dispatcher asks its printer for the browser by its Chromium id, answers once the
//     printer is done with i32 1, i64 size and the PDF's region as the frame's one descriptor,
//     and answers 0 with no descriptor for a page that did not print, with no printer, past
//     kMaxPrintsInFlight, or for a browser whose creation has not come;
//   - an op before initialize waits for it; a printer done after the dispatcher is gone only
//     closes its region; the HELLO lists kPrintToPdfHelloName only with a printer;
//   - end to end with the real remote shim (client/, loaded as cmux loads it) on a socket pair:
//     cmux_remote_shim_print_to_pdf sends only to a host that prints, its REPLY reaches the
//     reply callback under cmux_remote_shim_last_reply_token, the callback takes the PDF's
//     sealed region with cmux_remote_shim_take_reply_region and reads the host's bytes, and a
//     region the callback leaves is closed when it returns;
//   - a print the page starts (window.print()): kOpPagePrints installs the fork's print request
//     handler (after initialize; only on a host whose HELLO lists kPagePrintsHelloName, which needs
//     the hook and a printer), each request goes to cmux as CMUX_SHIM_PAGE_PRINT under cmux's id,
//     kOpPagePrintEnd ends it in the fork once, and a request cmux cannot take (page prints off,
//     past kMaxPagePrintRequests) ends at once; turning page prints off ends the waiting ones, and a
//     closed page's request is forgotten; end to end, cmux_remote_shim_set_page_prints reaches the
//     host and every later host of the session, the request reaches cmux's event callback, and
//     cmux_remote_shim_page_print_end ends it in the fork.
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_print.h"
#include "remote_shim_runtime.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;
using cmux_host::control::Message;
using Writer = cmux_host::control::TlvWriter;

constexpr int32_t kMinted = 1 << 20;
constexpr int kChromium = 3;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

struct Shim {
  HostContext* host = nullptr;
  int live = 0;
} shim;

// The fork's print request hook: what the host installed, and the requests it ended.
struct Fork {
  PrintRequestFn fn = nullptr;
  void* ctx = nullptr;
  int sets = 0;
  int set_result = 1;
  std::vector<int64_t> ended;
} fork;

int FakeSetPrintRequestHandler(PrintRequestFn fn, void* ctx) {
  ++fork.sets;
  fork.fn = fn;
  fork.ctx = ctx;
  return fn ? fork.set_result : 1;
}

int FakeEndPrintRequest(int64_t request) {
  fork.ended.push_back(request);
  return 1;
}

// The fork asks for page `chromium_id`'s print `request` through the installed handler.
void PageCallsPrint(int chromium_id, int64_t request) {
  if (fork.fn) fork.fn(fork.ctx, chromium_id, request);
}

}  // namespace

extern "C" {
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++shim.live;
  HostContext::OnShimEvent(shim.host, CMUX_SHIM_AFTER_CREATED, kChromium, request, 0, 0, "", "");
  return 1;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return shim.live; }
}

namespace {

// Prints what the test says, when it says: each Print is kept until Finish.
struct FakePrinter : PdfPrinter {
  struct Job {
    int browser;
    PrintToPdf print;
    Done done;
  };
  std::vector<Job> jobs;
  void Print(int chromium_id, const PrintToPdf& print, Done done) override {
    jobs.push_back({chromium_id, print, std::move(done)});
  }
  // Job `i` printed `pdf` (empty: did not print).
  void Finish(size_t i, const std::string& pdf) {
    Done done = std::move(jobs[i].done);
    if (pdf.empty()) return done(-1, 0);
    const int fd = control::CreateSharedRegion(pdf);
    Check(fd >= 0, "a region for the PDF");
    done(fd, pdf.size());
  }
};

struct Delegate : HostDelegate {
  std::vector<std::string> calls;
  std::function<void()> resume;
  void Initialize(InitializeRequest) override {
    calls.push_back("initialize");
    if (resume) resume();
  }
  void Quit() override {}
  void BrowserClosed() override {}
  void BadMessage(const std::string& what) override { calls.push_back("bad " + what); }
};

struct Views : PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const PageGeometry&) override {}
};

Message Op(uint16_t op, uint32_t token, std::vector<control::Field> fields) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = std::move(fields);
  return m;
}

std::vector<control::Field> Fields(int32_t browser, double width = 8.5, double height = 11) {
  PrintToPdf print;
  print.browser = browser;
  print.paper_width = width;
  print.paper_height = height;
  Writer w;
  WritePrintToPdf(print, &w);
  return w.Take();
}

// The bytes of region `fd` (0 bytes: not a sealed region of at least `size`).
std::string RegionBytes(int fd, uint64_t size) {
  struct stat info;
  if (fd < 0 || fstat(fd, &info) != 0 || static_cast<uint64_t>(info.st_size) < size || size == 0) return std::string();
  void* mapping = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
  if (mapping == MAP_FAILED) return std::string();
  std::string out(static_cast<const char*>(mapping), size);
  munmap(mapping, size);
  return out;
}

bool IsOpen(int fd) { return fcntl(fd, F_GETFD) != -1; }

void FieldsRoundTrip() {
  const std::optional<PrintToPdf> got = DecodePrintToPdf(Fields(kMinted, 8.27, 11.69));
  Check(got && got->browser == kMinted && got->paper_width == 8.27 && got->paper_height == 11.69,
        "a print round-trips");
  Check(DecodePrintToPdf(Fields(kMinted, 0, 0)).has_value(), "0 x 0 is Chromium's default paper");
  Check(!DecodePrintToPdf(Fields(kMinted, 8.5, 0)), "one side 0 without the other is refused");
  Check(!DecodePrintToPdf(Fields(kMinted, -1, 11)), "a negative side is refused");
  Check(!DecodePrintToPdf(Fields(kMinted, kMaxPaperInches + 1, 11)), "a side past the bound is refused");
  Check(!DecodePrintToPdf(Fields(kMinted, std::numeric_limits<double>::quiet_NaN(), 11)), "a NaN side is refused");
  std::vector<control::Field> extra = Fields(kMinted);
  extra.push_back(control::Field::I32(control::kTagValue, 1));
  Check(!DecodePrintToPdf(extra), "version 1 with an extra field is refused");
  std::vector<control::Field> later = Fields(kMinted);
  later[0].integer = 2;
  later.push_back(control::Field::I32(control::kTagValue, 1));
  Check(DecodePrintToPdf(later).has_value(), "a later version's appended field is left");
  std::vector<control::Field> zero = Fields(kMinted);
  zero[0].integer = 0;
  Check(!DecodePrintToPdf(zero), "version 0 is refused");
  std::vector<control::Field> missing = Fields(kMinted);
  missing.pop_back();
  Check(!DecodePrintToPdf(missing), "a missing field is refused");
}

// The dispatcher with one browser (cmux's kMinted, Chromium's kChromium).
struct Fixture {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  FakePrinter printer;
  std::unique_ptr<HostContext> host;

  explicit Fixture(bool with_printer = true, bool initialize = true, bool hook = false) {
    host = std::make_unique<HostContext>(
        [this](const Message& m) {
          sent.push_back(m);
          // The channel duplicates a frame's descriptors; the sender keeps (and closes) its own.
          for (int& fd : sent.back().fds) fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
          return true;
        },
        delegate, views, nullptr, nullptr);
    shim = Shim();
    shim.host = host.get();
    fork = Fork();
    if (with_printer) host->SetPdfPrinter(&printer);
    if (hook) host->SetPagePrintHook(&FakeSetPrintRequestHandler, &FakeEndPrintRequest);
    host->Attach();
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host->OnMessages({Op(control::kOpHello, 0, hello.Take())});
    if (initialize) Initialize();
  }
  ~Fixture() {
    for (Message& m : sent) {
      for (int fd : m.fds) close(fd);
    }
  }
  void Initialize() {
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host->OnMessages({Op(kOpInitialize, 1, init.Take())});
    host->Resume();
    Writer create;
    create.I32(kMinted);
    create.I32(42);
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host->OnMessages({Op(kOpCreateWindow, 2, create.Take())});
    sent.clear();
  }
  // The REPLY to `token` sent so far, or nullptr.
  const Message* ReplyTo(uint32_t token) const {
    for (const Message& m : sent) {
      if (m.op == kOpReply && m.reply && m.token == token) return &m;
    }
    return nullptr;
  }
  // The CMUX_SHIM_PAGE_PRINT events sent so far, as (browser, request).
  std::vector<std::pair<int32_t, int64_t>> PagePrints() const {
    std::vector<std::pair<int32_t, int64_t>> out;
    for (const Message& m : sent) {
      if (m.op != kOpEvent) continue;
      control::TlvReader r(m.fields);
      const int32_t kind = r.I32();
      const int32_t browser = r.I32();
      r.I32();
      const int64_t a = r.I64();
      if (r.ok() && kind == kEventPagePrint) out.emplace_back(browser, a);
    }
    return out;
  }
  // The reply's (printed, size); (-1, -1) when it is not that shape.
  static std::pair<int32_t, int64_t> Answer(const Message& reply) {
    control::TlvReader r(reply.fields);
    const int32_t printed = r.I32();
    const int64_t size = r.I64();
    if (!r.ok() || !r.AtEnd()) return {-1, -1};
    return {printed, size};
  }
};

std::vector<std::string> HelloExports(const std::vector<Message>& sent) {
  for (const Message& m : sent) {
    if (m.op != control::kOpHello) continue;
    control::TlvReader r(m.fields);
    r.Str();
    return r.StrList();
  }
  return {};
}

bool Lists(const std::vector<std::string>& exports, const char* name) {
  for (const std::string& e : exports) {
    if (e == name) return true;
  }
  return false;
}

void HelloSaysItPrints() {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  FakePrinter printer;
  HostContext with([&sent](const Message& m) { sent.push_back(m); return true; }, delegate, views, nullptr, nullptr);
  with.SetPdfPrinter(&printer);
  with.Attach();
  Check(Lists(HelloExports(sent), kPrintToPdfHelloName), "a host with a printer lists the print in its HELLO");
  sent.clear();
  HostContext without([&sent](const Message& m) { sent.push_back(m); return true; }, delegate, views, nullptr, nullptr);
  without.Attach();
  Check(!Lists(HelloExports(sent), kPrintToPdfHelloName), "a host without one does not");
}

void PrintsThroughThePrinter() {
  Fixture f;
  f.host->OnMessages({Op(kOpPrintToPdf, 7, Fields(kMinted))});
  Check(f.printer.jobs.size() == 1 && f.printer.jobs[0].browser == kChromium,
        "the printer prints the page's Chromium browser");
  Check(f.printer.jobs.size() == 1 && f.printer.jobs[0].print.paper_width == 8.5 &&
            f.printer.jobs[0].print.paper_height == 11,
        "at cmux's paper");
  Check(f.ReplyTo(7) == nullptr && f.host->prints_in_flight() == 1, "no answer until the PDF is made");
  const std::string pdf = "%PDF-1.7\n" + std::string(200000, 'x') + "\n%%EOF\n";  // past one frame's body
  f.printer.Finish(0, pdf);
  const Message* reply = f.ReplyTo(7);
  Check(reply != nullptr, "answered once printed");
  if (!reply) return;
  Check(Fixture::Answer(*reply) == std::make_pair(int32_t{1}, static_cast<int64_t>(pdf.size())), "1 and the PDF's size");
  Check(reply->fds.size() == 1, "the PDF's region is the frame's one descriptor");
  if (reply->fds.size() == 1) Check(RegionBytes(reply->fds[0], pdf.size()) == pdf, "the region holds the PDF");
  Check(f.host->prints_in_flight() == 0, "nothing in flight after");
  Check(f.delegate.calls == std::vector<std::string>({"initialize"}), "no bad message");
}

void UnprintedAnswersZero() {
  Fixture f;
  f.host->OnMessages({Op(kOpPrintToPdf, 7, Fields(kMinted))});
  f.printer.Finish(0, "");
  const Message* reply = f.ReplyTo(7);
  Check(reply && Fixture::Answer(*reply) == std::make_pair(int32_t{0}, int64_t{0}) && reply->fds.empty(),
        "a page that did not print: 0, no region");

  Fixture none(false);
  none.host->OnMessages({Op(kOpPrintToPdf, 8, Fields(kMinted))});
  reply = none.ReplyTo(8);
  Check(reply && Fixture::Answer(*reply).first == 0 && reply->fds.empty(), "no printer: 0 at once");
}

void InFlightIsBounded() {
  Fixture f;
  for (uint32_t token = 10; token < 10 + 9; ++token) f.host->OnMessages({Op(kOpPrintToPdf, token, Fields(kMinted))});
  Check(f.printer.jobs.size() == 8, "eight print at once");
  const Message* over = f.ReplyTo(18);
  Check(over && Fixture::Answer(*over).first == 0, "the ninth is answered 0 at once");
  f.printer.Finish(0, "%PDF");
  f.host->OnMessages({Op(kOpPrintToPdf, 19, Fields(kMinted))});
  Check(f.printer.jobs.size() == 9, "a finished print makes room for the next");
  Check(f.delegate.calls == std::vector<std::string>({"initialize"}), "the bound ends no host");
}

void MalformedEndsTheHost() {
  Fixture f;
  f.host->OnMessages({Op(kOpPrintToPdf, 0, Fields(kMinted))});
  Check(f.delegate.calls.size() == 2 && f.delegate.calls[1] == "bad a malformed print to PDF",
        "a print with no token is a bad message");
  Fixture g;
  g.host->OnMessages({Op(kOpPrintToPdf, 3, Fields(kMinted, -2, 11))});
  Check(g.delegate.calls.size() == 2 && g.printer.jobs.empty(), "a bad paper is a bad message, nothing printed");
}

void WaitsForInitialize() {
  Fixture f(true, false);
  f.host->OnMessages({Op(kOpPrintToPdf, 5, Fields(kChromium))});
  Check(f.printer.jobs.empty() && f.ReplyTo(5) == nullptr, "before initialize the print waits");
  Writer init;
  for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
  init.Str(nullptr);
  init.I32(0);
  init.Str(nullptr);
  init.Str(nullptr);
  init.StrList(nullptr, 0);
  f.host->OnMessages({Op(kOpInitialize, 1, init.Take())});
  Check(f.printer.jobs.empty(), "and while initialize runs");
  f.host->Resume();
  Check(f.printer.jobs.size() == 1 && f.printer.jobs[0].browser == kChromium, "then prints");
}

void DoneAfterTheHostOnlyCloses() {
  auto f = std::make_unique<Fixture>();
  f->host->OnMessages({Op(kOpPrintToPdf, 7, Fields(kMinted))});
  PdfPrinter::Done done = std::move(f->printer.jobs[0].done);
  const int fd = control::CreateSharedRegion("%PDF");
  f.reset();
  done(fd, 4);
  Check(!IsOpen(fd), "a PDF made after the host's context went is closed, nothing sent");
}

// --- prints the page starts -----------------------------------------------------------------

std::vector<control::Field> PagePrintsFields(bool enabled) {
  Writer w;
  WritePagePrints(enabled, &w);
  return w.Take();
}

std::vector<control::Field> EndFields(int64_t request) {
  Writer w;
  WritePagePrintEnd(request, &w);
  return w.Take();
}

void PagePrintFieldsRoundTrip() {
  Check(DecodePagePrints(PagePrintsFields(true)) == std::optional<bool>(true), "page prints on round-trips");
  Check(DecodePagePrints(PagePrintsFields(false)) == std::optional<bool>(false), "and off");
  std::vector<control::Field> two = PagePrintsFields(true);
  two[1].integer = 2;
  Check(!DecodePagePrints(two), "enabled is 0 or 1");
  std::vector<control::Field> extra = PagePrintsFields(true);
  extra.push_back(control::Field::I32(control::kTagValue, 1));
  Check(!DecodePagePrints(extra), "version 1 with an extra field is refused");
  extra[0].integer = 2;
  Check(DecodePagePrints(extra) == std::optional<bool>(true), "a later version's appended field is left");
  Check(DecodePagePrintEnd(EndFields(int64_t{1} << 40)) == std::optional<int64_t>(int64_t{1} << 40),
        "an end round-trips its request");
  Check(!DecodePagePrintEnd(EndFields(0)), "request 0 is refused");
  std::vector<control::Field> zero = EndFields(5);
  zero[0].integer = 0;
  Check(!DecodePagePrintEnd(zero), "version 0 is refused");
}

void PagePrintRequestsAreBounded() {
  PagePrintRequests requests;
  Check(!requests.Add(0, kChromium), "request 0 is not kept");
  Check(requests.Add(1, kChromium) && !requests.Add(1, kChromium), "a request is kept once");
  for (int64_t r = 2; r <= static_cast<int64_t>(kMaxPagePrintRequests); ++r) requests.Add(r, 100 + static_cast<int>(r));
  Check(requests.size() == kMaxPagePrintRequests, "kMaxPagePrintRequests wait");
  Check(!requests.Add(1000, kChromium), "one past the bound is not kept");
  requests.BrowserClosed(kChromium);
  Check(requests.size() == kMaxPagePrintRequests - 1 && !requests.End(1), "a closed page's request is forgotten");
  Check(requests.End(2) && !requests.End(2), "an end finds its request once");
  Check(requests.TakeAll().size() == kMaxPagePrintRequests - 2 && requests.size() == 0, "TakeAll empties it");
}

void HelloSaysItTakesPagePrints() {
  std::vector<Message> sent;
  Delegate delegate;
  Views views;
  FakePrinter printer;
  HostContext with([&sent](const Message& m) { sent.push_back(m); return true; }, delegate, views, nullptr, nullptr);
  with.SetPdfPrinter(&printer);
  with.SetPagePrintHook(&FakeSetPrintRequestHandler, &FakeEndPrintRequest);
  with.Attach();
  Check(Lists(HelloExports(sent), kPagePrintsHelloName), "the hook and a printer: the HELLO lists page prints");
  sent.clear();
  HostContext no_printer([&sent](const Message& m) { sent.push_back(m); return true; }, delegate, views, nullptr,
                         nullptr);
  no_printer.SetPagePrintHook(&FakeSetPrintRequestHandler, &FakeEndPrintRequest);
  no_printer.Attach();
  Check(!Lists(HelloExports(sent), kPagePrintsHelloName), "no printer: no page prints");
  sent.clear();
  HostContext no_end([&sent](const Message& m) { sent.push_back(m); return true; }, delegate, views, nullptr, nullptr);
  no_end.SetPdfPrinter(&printer);
  no_end.SetPagePrintHook(&FakeSetPrintRequestHandler, nullptr);
  no_end.Attach();
  Check(!Lists(HelloExports(sent), kPagePrintsHelloName), "half a hook: no page prints");
}

// window.print() of the page: to cmux under its id, ended in the fork when cmux ends it, once.
void APagePrintGoesToCmuxAndEndsOnce() {
  Fixture f(true, true, true);
  PageCallsPrint(kChromium, 77);
  Check(fork.sets == 0 && f.PagePrints().empty(), "until cmux asks, Chromium keeps its preview");
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  Check(fork.sets == 1 && fork.fn == &HostContext::OnPagePrint && fork.ctx == f.host.get(),
        "the handler is installed");
  PageCallsPrint(kChromium, 77);
  Check(f.PagePrints() == std::vector<std::pair<int32_t, int64_t>>({{kMinted, 77}}), "cmux gets it under its id");
  Check(fork.ended.empty() && f.host->page_prints_waiting() == 1, "the page waits for cmux");
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  Check(fork.sets == 1, "on again installs nothing more");
  f.host->OnMessages({Op(kOpPagePrintEnd, 0, EndFields(77))});
  Check(fork.ended == std::vector<int64_t>({77}), "cmux's end ends it in the fork");
  f.host->OnMessages({Op(kOpPagePrintEnd, 0, EndFields(77))});
  Check(fork.ended.size() == 1 && f.host->page_prints_waiting() == 0, "once");
  Check(f.delegate.calls == std::vector<std::string>({"initialize"}), "no bad message");
}

void APagePrintCmuxCannotTakeEndsAtOnce() {
  Fixture f(true, true, true);
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  for (int64_t r = 1; r <= static_cast<int64_t>(kMaxPagePrintRequests) + 1; ++r) PageCallsPrint(kChromium, r);
  Check(f.PagePrints().size() == kMaxPagePrintRequests, "kMaxPagePrintRequests go to cmux");
  Check(fork.ended == std::vector<int64_t>({static_cast<int64_t>(kMaxPagePrintRequests) + 1}),
        "the one past the bound ends at once");
  const PrintRequestFn handler = fork.fn;
  void* ctx = fork.ctx;
  fork.ended.clear();
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(false))});
  Check(fork.fn == nullptr && fork.sets == 2, "off clears the handler");
  Check(fork.ended.size() == kMaxPagePrintRequests && f.host->page_prints_waiting() == 0,
        "and ends every waiting request");
  fork.ended.clear();
  handler(ctx, kChromium, 900);  // a request the fork made before it saw the handler go
  Check(fork.ended == std::vector<int64_t>({900}) && f.PagePrints().size() == kMaxPagePrintRequests,
        "a request after off ends at once, cmux never sees it");
}

void AClosedPagesRequestIsForgotten() {
  Fixture f(true, true, true);
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  PageCallsPrint(kChromium, 5);
  HostContext::OnShimEvent(f.host.get(), CMUX_SHIM_BEFORE_CLOSE, kChromium, 0, 0, 0, "", "");
  Check(f.host->page_prints_waiting() == 0, "the page's close forgets its request");
  f.host->OnMessages({Op(kOpPagePrintEnd, 0, EndFields(5))});
  Check(fork.ended.empty(), "the fork ended it with the page: cmux's late end asks it nothing");
}

void PagePrintsWaitForInitialize() {
  Fixture f(true, false, true);
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  Check(fork.sets == 0, "before initialize the handler waits");
  f.Initialize();
  Check(fork.sets == 1 && fork.fn != nullptr, "then it is installed");
}

void ARefusedHandlerSendsCmuxNothing() {
  Fixture f(true, true, true);
  fork.set_result = 0;
  f.host->OnMessages({Op(kOpPagePrints, 0, PagePrintsFields(true))});
  // A fork that refused never calls it; should it still, the request goes back to Chromium.
  PageCallsPrint(kChromium, 9);
  Check(f.PagePrints().empty() && fork.ended == std::vector<int64_t>({9}), "a refused handler sends cmux nothing");
}

void MalformedPagePrintOpsEndTheHost() {
  Fixture f(true, true, true);
  std::vector<control::Field> bad = PagePrintsFields(true);
  bad[1].integer = 3;
  f.host->OnMessages({Op(kOpPagePrints, 0, bad)});
  Check(f.delegate.calls.size() == 2 && f.delegate.calls[1] == "bad a malformed page prints", "a bad enabled is bad");
  Fixture g(true, true, true);
  g.host->OnMessages({Op(kOpPagePrintEnd, 0, EndFields(0))});
  Check(g.delegate.calls.size() == 2 && g.delegate.calls[1] == "bad a malformed page print end",
        "an end of request 0 is bad");
}

// --- end to end with the real remote shim ---------------------------------------------------

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

struct Client {
  decltype(&cmux_remote_shim_configure) configure;
  decltype(&cmux_remote_shim_attach) attach;
  decltype(&cmux_remote_shim_detach) detach;
  decltype(&cmux_remote_shim_set_reply) set_reply;
  decltype(&cmux_remote_shim_last_reply_token) last_reply_token;
  decltype(&cmux_remote_shim_print_to_pdf) print_to_pdf;
  decltype(&cmux_remote_shim_take_reply_region) take_reply_region;
  decltype(&cmux_remote_shim_set_page_prints) set_page_prints;
  decltype(&cmux_remote_shim_page_print_end) page_print_end;
  decltype(&cmux_shim_initialize) initialize;
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
  Bind(library, "cmux_remote_shim_set_reply", &c.set_reply);
  Bind(library, "cmux_remote_shim_last_reply_token", &c.last_reply_token);
  Bind(library, "cmux_remote_shim_print_to_pdf", &c.print_to_pdf);
  Bind(library, "cmux_remote_shim_take_reply_region", &c.take_reply_region);
  Bind(library, "cmux_remote_shim_set_page_prints", &c.set_page_prints);
  Bind(library, "cmux_remote_shim_page_print_end", &c.page_print_end);
  Bind(library, "cmux_shim_initialize", &c.initialize);
  return c;
}

Client client;
bool ready = false;
bool initialized = false;

// What the reply callback saw: the token, its fields' bytes, the region it took (or left).
struct Replies {
  bool take = true;
  std::vector<uint32_t> tokens;
  std::vector<int32_t> printed;
  std::vector<std::string> pdfs;
  std::vector<int> regions;
} replies;

void OnReply(void*, uint32_t token, const void* fields, size_t length) {
  replies.tokens.push_back(token);
  std::vector<control::Field> decoded;
  control::DecodeFields(std::string_view(static_cast<const char*>(fields), length), &decoded);
  control::TlvReader r(decoded);
  const int32_t printed = r.I32();
  const int64_t size = r.I64();
  replies.printed.push_back(printed);
  if (!replies.take) {
    replies.regions.push_back(-1);
    replies.pdfs.emplace_back();
    return;
  }
  const int region = client.take_reply_region();
  replies.regions.push_back(region);
  replies.pdfs.push_back(region >= 0 && size > 0 ? RegionBytes(region, static_cast<uint64_t>(size)) : std::string());
  Check(client.take_reply_region() == -1, "a region is taken once");
}

void OnReady(void*) { ready = true; }
// The CMUX_SHIM_PAGE_PRINT events cmux's event callback got, as (browser, request).
std::vector<std::pair<int, int64_t>> page_print_events;
void OnEvent(void*, int kind, int browser, int, int64_t a, int64_t, const char*, const char*) {
  if (kind == kEventPagePrint) page_print_events.emplace_back(browser, a);
}

// One host (the real dispatcher, `printer` its printer or none) and the attached remote shim.
struct World {
  Delegate delegate;
  Views views;
  FakePrinter printer;
  std::unique_ptr<control::Channel> channel;
  std::unique_ptr<HostContext> host;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);

  explicit World(bool prints, bool hook = false) {
    host = std::make_unique<HostContext>([this](const Message& m) { return channel && channel->Send(m); }, delegate,
                                         views, nullptr, nullptr);
    shim = Shim();
    shim.host = host.get();
    fork = Fork();
    page_print_events.clear();
    if (prints) host->SetPdfPrinter(&printer);
    if (hook) host->SetPagePrintHook(&FakeSetPrintRequestHandler, &FakeEndPrintRequest);
    ready = false;
    replies = Replies();
    // A resume still queued when this world goes runs on nothing: the next world reuses the queue.
    delegate.resume = [this, alive = alive] { PostTask([this, alive] { if (*alive) host->Resume(); }); };
    int pair[2];
    Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
    channel = std::make_unique<control::Channel>(
        pair[1], &PostTask, [this](std::vector<Message> batch) { host->OnMessages(std::move(batch)); },
        [](control::End) {});
    host->Attach();
    Check(client.attach(pair[0], nullptr, nullptr) == 1, "the remote shim attaches");
    client.set_reply(nullptr, &OnReply);
    if (!initialized) {
      const char* switches[] = {nullptr};
      Check(client.initialize("/fw", "/app", "/helper", "/root", nullptr, 0, nullptr, nullptr, switches, nullptr,
                              nullptr, &OnEvent, nullptr) == 1,
            "initialize is sent");
      initialized = true;
    }
    Check(PumpUntil([] { return ready; }), "the hellos go through");
    PumpUntil([this] { return delegate.calls.size() == 1; });
  }
  ~World() {
    *alive = false;
    client.detach();
    channel->Close();
    channel.reset();
  }
};

void EndToEnd() {
  World world(true);
  Check(client.print_to_pdf(kChromium, 8.5, 11) == 1, "a host that prints takes the op");
  const uint32_t token = client.last_reply_token();
  Check(token != 0, "under a reply token");
  Check(PumpUntil([&] { return world.printer.jobs.size() == 1; }), "the host's printer gets it");
  const std::string pdf = "%PDF-1.7\n" + std::string(300000, 'p') + "\n%%EOF\n";
  world.printer.Finish(0, pdf);
  Check(PumpUntil([] { return !replies.tokens.empty(); }), "the REPLY reaches the reply callback");
  if (replies.tokens.empty()) return;
  Check(replies.tokens[0] == token && replies.printed[0] == 1, "printed, under the call's token");
  Check(replies.pdfs[0] == pdf, "the callback reads the host's PDF from the region it took");
  if (replies.regions[0] >= 0) close(replies.regions[0]);

  Check(client.print_to_pdf(kChromium, -1, 11) == 0 && client.last_reply_token() == 0, "a refused paper sends nothing");
  Check(client.take_reply_region() == -1, "outside a reply there is no region");

  // A region the callback leaves goes with the delivery.
  replies.take = false;
  Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a second print");
  Check(PumpUntil([&] { return world.printer.jobs.size() == 2; }), "printing");
  const int before = fcntl(0, F_DUPFD_CLOEXEC, 0);  // the lowest free descriptor now
  close(before);
  world.printer.Finish(1, "%PDF-small");
  Check(PumpUntil([] { return replies.tokens.size() == 2; }), "its REPLY");
  const int after = fcntl(0, F_DUPFD_CLOEXEC, 0);
  close(after);
  Check(after == before, "the untaken region was closed (no descriptor leaked)");

  // A page that did not print: 0 and no region.
  replies.take = true;
  Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a third print");
  Check(PumpUntil([&] { return world.printer.jobs.size() == 3; }), "printing");
  world.printer.Finish(2, "");
  Check(PumpUntil([] { return replies.tokens.size() == 3; }), "its REPLY");
  if (replies.tokens.size() == 3) Check(replies.printed[2] == 0 && replies.regions[2] == -1, "0, no region");
}

// A page's window.print() end to end: cmux turns page prints on, the fork's request reaches cmux's
// event callback, cmux's end reaches the fork; a later host of the session gets page prints at its
// attach, and a host without the hook is never asked.
void PagePrintsEndToEnd() {
  {
    World world(true, true);
    Check(client.set_page_prints(1) == 1, "a host with the hook takes page prints");
    Check(PumpUntil([] { return fork.fn != nullptr; }), "the host installs the fork's handler");
    PageCallsPrint(kChromium, 41);
    Check(PumpUntil([] { return !page_print_events.empty(); }), "the page's print reaches cmux");
    if (!page_print_events.empty()) {
      Check(page_print_events[0] == std::make_pair(kChromium, int64_t{41}), "with the page and the request");
    }
    Check(client.page_print_end(41) == 1, "cmux ends it");
    Check(PumpUntil([] { return !fork.ended.empty(); }) && fork.ended == std::vector<int64_t>({41}),
          "the fork's request ends: the page's window.print() returns");
    Check(client.page_print_end(0) == 0, "request 0 sends nothing");
  }
  {
    World next(true, true);
    Check(PumpUntil([] { return fork.fn != nullptr; }), "the session's next host gets page prints at its attach");
  }
  {
    World without(true, false);
    Check(client.set_page_prints(1) == 0, "a host without the hook does not take page prints");
    Check(client.page_print_end(41) == 0, "nor an end");
  }
  client.set_page_prints(0);
}

void AHostThatDoesNotPrintIsNeverAsked() {
  World world(false);
  Check(client.print_to_pdf(kChromium, 8.5, 11) == 0 && client.last_reply_token() == 0,
        "a host whose HELLO lists no print gets no op");
}

// Whether a descriptor of this process is open on the file `info` names.
bool AnyOpenOn(const struct stat& info) {
  for (int fd = 0; fd < 4096; ++fd) {
    struct stat open;
    if (fstat(fd, &open) == 0 && open.st_dev == info.st_dev && open.st_ino == info.st_ino) return true;
  }
  return false;
}

// A host that is only its end of the channel: the test writes its frames, so several reach the
// remote shim together, before cmux's main thread delivers them.
struct RawHost {
  std::unique_ptr<control::Channel> channel;

  RawHost() {
    ready = false;
    replies = Replies();
    int pair[2];
    Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
    channel = std::make_unique<control::Channel>(
        pair[1], &PostTask, [](std::vector<Message>) {}, [](control::End) {});
    Check(client.attach(pair[0], nullptr, nullptr) == 1, "the remote shim attaches");
    Writer hello;
    hello.Str(kWireID);
    const char* exports[] = {kPrintToPdfHelloName};
    hello.StrList(exports, 1);
    Send(Op(control::kOpHello, 0, hello.Take()));
    Check(PumpUntil([] { return ready; }), "the raw host's hello goes through");
  }
  ~RawHost() {
    client.detach();
    channel->Close();
    channel.reset();
  }

  void Send(const Message& message) { Check(channel->Send(message), "the raw host sends"); }

  // A kOpPrintToPdf REPLY under `token`: printed with `pdf`'s size, its region `fds`.
  void Reply(uint32_t token, const std::string& pdf, std::vector<int> fds) {
    Writer w;
    w.I32(pdf.empty() ? 0 : 1);
    w.I64(static_cast<int64_t>(pdf.size()));
    Message reply = Op(kOpReply, token, w.Take());
    reply.reply = true;
    reply.fds = std::move(fds);
    Send(reply);
  }
};

uint32_t detach_on = 0;
void OnReplyDetaching(void*, uint32_t token, const void*, size_t) {
  replies.tokens.push_back(token);
  if (token == detach_on) client.detach();
}

const std::string kBatchPdf = "%PDF-1.7 batch";

// Sends `frames` (each may carry `region`, a region of kBatchPdf) together, then waits until the
// remote shim delivered them and no descriptor of the process is open on the region: none leaked.
void ExpectRegionClosed(const std::function<void(int region)>& frames, const std::string& what) {
  const int region = control::CreateSharedRegion(kBatchPdf);
  Check(region >= 0, "a region for the PDF");
  struct stat info;
  Check(fstat(region, &info) == 0, "the region's file");
  frames(region);
  close(region);  // the channel sent its duplicate
  // Both frames reach the remote shim's reader before cmux's main thread delivers either.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  Check(PumpUntil([&] { return !AnyOpenOn(info); }), what);
}

// A REPLY's descriptor never outlives its batch: the messages left when a callback detaches, or
// after a malformed frame, have theirs closed, and a frame other than a REPLY may carry none.
void ABatchThatStopsClosesItsRegions() {
  {
    RawHost host;
    Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a first print");
    const uint32_t first = client.last_reply_token();
    Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a second print");
    const uint32_t second = client.last_reply_token();
    detach_on = first;
    client.set_reply(nullptr, &OnReplyDetaching);
    ExpectRegionClosed([&](int region) {
      host.Reply(first, "", {});
      host.Reply(second, kBatchPdf, {region});
    }, "a print REPLY after one whose callback detached has its region closed");
    Check(replies.tokens == std::vector<uint32_t>({first}), "the detach dropped the second REPLY");
    client.set_reply(nullptr, &OnReply);
  }
  {
    RawHost host;
    Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a print");
    const uint32_t token = client.last_reply_token();
    ExpectRegionClosed([&](int region) {
      Message malformed = Op(kOpAck, 0, {control::Field::I32(1, 1)});
      host.Send(malformed);
      host.Reply(token, kBatchPdf, {region});
    }, "a print REPLY after a malformed frame has its region closed");
    Check(replies.tokens.empty(), "the malformed frame ended the host before the REPLY");
  }
  {
    RawHost host;
    Check(client.print_to_pdf(kChromium, 0, 0) == 1, "a print");
    const uint32_t token = client.last_reply_token();
    ExpectRegionClosed([&](int region) {
      Message ack = Op(kOpAck, token, {});
      ack.fds = {region};
      host.Send(ack);
    }, "an ACK that carries a descriptor is malformed, and the descriptor is closed");
    Check(client.print_to_pdf(kChromium, 0, 0) == 0, "the frame ended the host");
  }
}

}  // namespace

int main() {
  FieldsRoundTrip();
  HelloSaysItPrints();
  PrintsThroughThePrinter();
  UnprintedAnswersZero();
  InFlightIsBounded();
  MalformedEndsTheHost();
  WaitsForInitialize();
  DoneAfterTheHostOnlyCloses();
  PagePrintFieldsRoundTrip();
  PagePrintRequestsAreBounded();
  HelloSaysItTakesPagePrints();
  APagePrintGoesToCmuxAndEndsOnce();
  APagePrintCmuxCannotTakeEndsAtOnce();
  AClosedPagesRequestIsForgotten();
  PagePrintsWaitForInitialize();
  ARefusedHandlerSendsCmuxNothing();
  MalformedPagePrintOpsEndTheHost();
  client = LoadClient();
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ready = &OnReady;
  client.configure(&callbacks);
  AHostThatDoesNotPrintIsNeverAsked();
  EndToEnd();
  PagePrintsEndToEnd();
  ABatchThatStopsClosesItsRegions();
  if (failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("host_print_test: ok\n");
  return 0;
}
