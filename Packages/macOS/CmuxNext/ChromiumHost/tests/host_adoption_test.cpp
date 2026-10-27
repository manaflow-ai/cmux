// The adoption of a Chromium Host by a relaunched cmux (src/host_adoption.h,
// task p01-process-150): the golden offer frame that ChromiumHostAdoptionTests
// checks too, the verdicts (a version mismatch never adopts), the socket path
// and its short alias, a listening socket of mode 0600 that a connect reaches,
// which channel ends leave an orphan (none after cmux's quit began, none for a
// host that trusts no peer), the adopted pages an adopted reply lists and only
// it, and a mismatched cmux's offer ending the host as a quit: every page
// closes and the process ends within the quit limit (host_quit.h). Built and
// run by scripts/cmux-next/tests/chromium-host-wire.test.sh.
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "../src/chromium_host_tlv.h"
#include "../src/chromium_host_wire.h"
#include "../src/host_adoption.h"
#include "../src/host_quit.h"

namespace adoption = cmux_host::adoption;
namespace control = cmux_host::control;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what.c_str());
  }
}

static std::string HexOf(const std::vector<uint8_t>& bytes) {
  static const char kDigits[] = "0123456789abcdef";
  std::string out;
  for (uint8_t b : bytes) {
    out.push_back(kDigits[b >> 4]);
    out.push_back(kDigits[b & 15]);
  }
  return out;
}

static adoption::Offer GoldenOffer() {
  adoption::Offer offer;
  offer.wire_id = "w1";
  offer.abi_id = "a1";
  offer.min_fork_api = 30;
  offer.framework = {1, 2, 3, 4};
  offer.app_pid = 4242;
  return offer;
}

// The same bytes as ChromiumHostAdoptionTests.goldenOffer.
static const char kGoldenOffer[] =
    "4c0000002080000000000000050002007731050002006131010004001e000000"
    "0200080001000000000000000200080002000000000000000200080003000000"
    "000000000200080004000000000000000100040092100000";

static void TestGoldenOffer() {
  std::vector<uint8_t> frame;
  Check(control::Encode(adoption::EncodeOffer(GoldenOffer()), &frame), "the offer encodes");
  Check(HexOf(frame) == kGoldenOffer, "the golden offer: " + HexOf(frame));
  std::deque<int> fds;
  control::Message decoded;
  size_t consumed = 0;
  Check(control::Decode(frame.data(), frame.size(), &fds, &decoded, &consumed) == control::Parse::kFrame,
        "the offer decodes");
  const std::optional<adoption::Offer> offer = adoption::ReadOffer(decoded);
  Check(offer && offer->wire_id == "w1" && offer->abi_id == "a1" && offer->min_fork_api == 30 &&
            offer->framework == adoption::FrameworkIdentity{1, 2, 3, 4} && offer->app_pid == 4242,
        "the offer reads back");
}

static void TestReadOfferRefusesOtherFrames() {
  control::Message other = adoption::EncodeOffer(GoldenOffer());
  other.op = control::kOpHello;
  Check(!adoption::ReadOffer(other), "another op is no offer");
  control::Message short_offer = adoption::EncodeOffer(GoldenOffer());
  short_offer.fields.pop_back();
  Check(!adoption::ReadOffer(short_offer), "an offer with a field missing is malformed");
  control::Message reply = adoption::EncodeOffer(GoldenOffer());
  reply.reply = true;
  Check(!adoption::ReadOffer(reply), "a reply frame is no offer");
  adoption::Offer launchd = GoldenOffer();
  launchd.app_pid = 1;
  Check(!adoption::ReadOffer(adoption::EncodeOffer(launchd)), "an offer naming no app pid is malformed");
}

static void TestJudge() {
  const adoption::HostVersions host{"w1", "a1", 31, {1, 2, 3, 4}};
  Check(adoption::Judge(GoldenOffer(), host) == adoption::Verdict::kAdopted, "the same wire, ABI and framework adopt");
  adoption::Offer other_wire = GoldenOffer();
  other_wire.wire_id = "w2";
  Check(adoption::Judge(other_wire, host) == adoption::Verdict::kVersionMismatch, "another wire is a mismatch");
  adoption::Offer other_abi = GoldenOffer();
  other_abi.abi_id = "a2";
  Check(adoption::Judge(other_abi, host) == adoption::Verdict::kVersionMismatch, "another shim ABI is a mismatch");
  adoption::Offer updated = GoldenOffer();
  updated.framework.inode = 9;
  Check(adoption::Judge(updated, host) == adoption::Verdict::kVersionMismatch,
        "a framework replaced by an update is a mismatch");
  adoption::Offer newer_fork = GoldenOffer();
  newer_fork.min_fork_api = 32;
  Check(adoption::Judge(newer_fork, host) == adoption::Verdict::kVersionMismatch,
        "a cmux that needs a newer fork API is a mismatch");
  Check(adoption::Judge(std::nullopt, host) == adoption::Verdict::kMalformed, "no offer is malformed");
  adoption::Offer declined = GoldenOffer();
  declined.wire_id.clear();
  Check(adoption::Judge(declined, host) == adoption::Verdict::kVersionMismatch,
        "an offer naming no wire (a cmux with crash survival off) is a mismatch: the host ends");
}

// The same bytes as ChromiumHostAdoptionTests.goldenReply: an adopted reply with one page.
static const char kGoldenReply[] =
    "7900000021800000000000000100040000000000010004004d00000001000400"
    "1f0000000100040000001000010004000000002005001400636f6d2e636d7578"
    "7465726d2e66656e63652e310200080005000000000000000100040002001000"
    "0100040007000000020008000300000000000000010004003412000005000500"
    "7461622d31";

static adoption::AdoptedPage GoldenPage() {
  adoption::AdoptedPage page;
  page.browser = (1 << 20) + 2;
  page.window = 7;
  page.view = 3;
  page.context = 0x1234;
  page.key = "tab-1";
  return page;
}

static adoption::Reply GoldenReply() {
  adoption::Reply reply;
  reply.verdict = adoption::Verdict::kAdopted;
  reply.host_pid = 77;
  reply.fork_api = 31;
  reply.mint_browser = 1 << 20;
  reply.mint_devtools = 1 << 29;
  reply.resize_fence = "com.cmuxterm.fence.1";
  reply.mint_view = 5;
  reply.pages = {GoldenPage()};
  return reply;
}

static void TestReply() {
  const adoption::Reply reply = GoldenReply();
  const std::optional<adoption::Reply> read = adoption::ReadReply(adoption::EncodeReply(reply));
  Check(read && read->verdict == adoption::Verdict::kAdopted && read->host_pid == 77 && read->fork_api == 31 &&
            read->mint_browser == (1 << 20) && read->mint_devtools == (1 << 29) &&
            read->resize_fence == "com.cmuxterm.fence.1" && read->mint_view == 5 &&
            read->pages == std::vector<adoption::AdoptedPage>{GoldenPage()},
        "the reply reads back with its view floor and page");
  std::vector<uint8_t> frame;
  control::Encode(adoption::EncodeReply(reply), &frame);
  Check(HexOf(frame) == kGoldenReply, "the golden reply: " + HexOf(frame));
  control::Message bad = adoption::EncodeReply(reply);
  bad.fields[0] = control::Field::I32(0, 3);
  Check(!adoption::ReadReply(bad), "an unknown verdict is malformed");
  adoption::Reply mismatch = reply;
  mismatch.verdict = adoption::Verdict::kVersionMismatch;
  Check(!adoption::ReadReply(adoption::EncodeReply(mismatch)), "only an adopted reply lists pages");
  mismatch.pages.clear();
  const std::optional<adoption::Reply> bare = adoption::ReadReply(adoption::EncodeReply(mismatch));
  Check(bare && bare->verdict == adoption::Verdict::kVersionMismatch && bare->pages.empty(),
        "a mismatch with no pages reads");
  adoption::Reply empty_key = reply;
  empty_key.pages[0].key.clear();
  Check(!adoption::ReadReply(adoption::EncodeReply(empty_key)), "a page with no key is malformed");
  control::Message cut = adoption::EncodeReply(reply);
  cut.fields.pop_back();
  Check(!adoption::ReadReply(cut), "a page cut short is malformed");
}

// The reply is one frame with no shared field (the adoption connection takes no descriptors): the pages
// past its bound are left out, and so is a key cmux could not have sent.
static void TestFitReplyPages() {
  adoption::Reply reply = GoldenReply();
  reply.pages.clear();
  std::vector<adoption::AdoptedPage> pages;
  adoption::AdoptedPage over = GoldenPage();
  over.key.assign(adoption::kMaxPageKeyBytes + 1, 'k');
  pages.push_back(over);
  for (int i = 0; i < 2000; ++i) {
    adoption::AdoptedPage page = GoldenPage();
    page.browser = (1 << 20) + i;
    page.key = std::string(200, 'a') + std::to_string(i);
    pages.push_back(page);
  }
  const std::vector<adoption::AdoptedPage> fit = adoption::FitReplyPages(reply, pages);
  Check(!fit.empty() && fit.size() < 2000 && fit.front().browser == (1 << 20),
        "the first pages fit, the over-long key is out");
  reply.pages = fit;
  std::vector<uint8_t> frame;
  Check(control::Encode(adoption::EncodeReply(reply), &frame) && frame.size() <= control::kHeaderSize + control::kMaxBody,
        "the fitted reply is one frame");
  reply.pages.push_back(pages[fit.size() + 1]);
  Check(!control::Encode(adoption::EncodeReply(reply), &frame), "one more page would break the frame bound");
}

static void TestSocketPath() {
  Check(adoption::SocketPath("/Users/a/Library/Application Support/com.cmuxterm.app/ChromiumHost", 501) ==
            "/Users/a/Library/Application Support/com.cmuxterm.app/ChromiumHost/chromium-host.sock",
        "a short root cache keeps the socket in it");
  Check(adoption::SocketPath("/r/", 501) == "/r/chromium-host.sock", "a trailing slash is dropped");
  const std::string long_root =
      "/Users/lawrence/Library/Application Support/com.cmuxterm.app.debug.p01-process-150-kill-app/ChromiumHost";
  Check(adoption::SocketPath(long_root, 501) == adoption::ShortSocketPath(long_root, 501),
        "a root cache past sun_path takes the short path");
  // The same value as ChromiumHostAdoptionTests.shortSocketPath (FNV-1a 64 of the root cache).
  Check(adoption::ShortSocketPath(long_root, 501) == "/tmp/cmux-chromium-host-501/" +
                                                         std::string([&] {
                                                           char hex[17];
                                                           std::snprintf(hex, sizeof hex, "%016llx",
                                                                         static_cast<unsigned long long>(
                                                                             adoption::Fnv1a64(long_root)));
                                                           return std::string(hex);
                                                         }()) +
                                                         ".sock",
        "the short path names the root cache's hash");
  Check(adoption::Fnv1a64("") == 0xcbf29ce484222325ull && adoption::Fnv1a64("a") == 0xaf63dc4c8601ec8cull,
        "FNV-1a 64 test vectors");
  Check(adoption::SocketPath("", 501).empty(), "no root cache, no socket");
}

static void TestListen() {
  char dir_template[] = "/tmp/host-adoption-test.XXXXXX";
  const char* dir = mkdtemp(dir_template);
  Check(dir != nullptr, "a scratch directory");
  if (!dir) return;
  const std::string path = std::string(dir) + "/chromium-host.sock";
  const int listener = adoption::Listen(path);
  Check(listener >= 0, "listens");
  struct stat info;
  Check(lstat(path.c_str(), &info) == 0 && S_ISSOCK(info.st_mode) && (info.st_mode & 0777) == 0600,
        "the socket file has mode 0600");
  const int client = socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  Check(connect(client, reinterpret_cast<const sockaddr*>(&address), sizeof address) == 0, "a client connects");
  const int accepted = accept(listener, nullptr, nullptr);
  Check(accepted >= 0, "the host accepts it");
  close(accepted);
  close(client);
  close(listener);
  // A host after this one finds the stale socket and takes the path.
  const int again = adoption::Listen(path);
  Check(again >= 0, "a stale socket is replaced");
  close(again);
  adoption::Unlisten(path);
  Check(lstat(path.c_str(), &info) != 0, "Unlisten removes the socket");
  // Any other file at the path is left alone.
  FILE* file = std::fopen(path.c_str(), "w");
  if (file) std::fclose(file);
  Check(adoption::Listen(path) < 0, "a regular file at the path is not replaced");
  unlink(path.c_str());
  rmdir(dir);
}

// A client of the adoption socket: connects, sends `frame` and reads one whole reply frame.
struct Client {
  int fd = -1;
  explicit Client(const std::string& path) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    for (int tries = 0; tries < 200; ++tries) {
      if (connect(fd, reinterpret_cast<const sockaddr*>(&address), sizeof address) == 0) return;
      usleep(5000);  // the listener thread binds the path
    }
    close(fd);
    fd = -1;
  }
  ~Client() {
    if (fd >= 0) close(fd);
  }
  bool Send(const control::Message& message) {
    std::vector<uint8_t> bytes;
    return control::Encode(message, &bytes) && write(fd, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size());
  }
  std::optional<control::Message> Read() {
    timeval tv{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    std::vector<uint8_t> bytes(control::kHeaderSize);
    if (recv(fd, bytes.data(), bytes.size(), MSG_WAITALL) != static_cast<ssize_t>(bytes.size())) return std::nullopt;
    const uint32_t length = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | static_cast<uint32_t>(bytes[3]) << 24;
    bytes.resize(control::kHeaderSize + length);
    if (length && recv(fd, bytes.data() + control::kHeaderSize, length, MSG_WAITALL) != static_cast<ssize_t>(length)) {
      return std::nullopt;
    }
    std::deque<int> fds;
    control::Message message;
    size_t consumed = 0;
    if (control::Decode(bytes.data(), bytes.size(), &fds, &message, &consumed) != control::Parse::kFrame) return std::nullopt;
    return message;
  }
};

struct ListenerRun {
  std::string dir;
  std::string path;
  std::vector<adoption::Listener::Outcome> outcomes;
  std::thread thread;

  explicit ListenerRun(std::chrono::milliseconds grace, int refuse = 0, std::vector<adoption::AdoptedPage> pages = {},
                       bool trusts_any_peer = true) {
    char dir_template[] = "/tmp/host-adoption-listen.XXXXXX";
    dir = mkdtemp(dir_template);
    path = dir + "/chromium-host.sock";
    adoption::Listener::Options options;
    options.path = path;
    options.versions = {"w1", "a1", 31, {1, 2, 3, 4}};
    options.reply.host_pid = 77;
    options.reply.fork_api = 31;
    options.reply.mint_browser = (1 << 20) + 5;
    options.reply.mint_devtools = 1 << 29;
    options.reply.resize_fence = "fence";
    options.reply.mint_view = 9;
    options.reply.pages = std::move(pages);
    options.trusts_any_peer = [trusts_any_peer] { return trusts_any_peer; };
    options.grace = grace;
    options.read_limit = std::chrono::milliseconds(500);
    auto refused = std::make_shared<int>(refuse);
    options.check_peer = [refused](int) -> std::optional<pid_t> {
      if (*refused > 0) {
        --*refused;
        return std::nullopt;
      }
      return getpid();
    };
    options.done = [this](adoption::Listener::Outcome outcome) { outcomes.push_back(outcome); };
    thread = std::thread([options]() mutable { adoption::Listener::Run(std::move(options)); });
  }
  ~ListenerRun() {
    if (thread.joinable()) thread.join();
    for (const auto& outcome : outcomes) {
      if (outcome.fd >= 0) close(outcome.fd);
    }
    unlink(path.c_str());
    rmdir(dir.c_str());
  }
  void Join() { thread.join(); }
};

static adoption::Offer OfferOfThisProcess() {
  adoption::Offer offer = GoldenOffer();
  offer.app_pid = getpid();
  return offer;
}

static void TestListenerAdopts() {
  ListenerRun run(std::chrono::seconds(10), /*refuse=*/1, {GoldenPage()});
  {
    Client untrusted(run.path);
    Check(untrusted.fd >= 0, "an untrusted client connects");
    untrusted.Send(adoption::EncodeOffer(OfferOfThisProcess()));
    Check(!untrusted.Read(), "a peer the check refuses gets no reply: closed unread");
  }
  Client client(run.path);
  Check(client.Send(adoption::EncodeOffer(OfferOfThisProcess())), "the offer goes");
  const std::optional<control::Message> frame = client.Read();
  const std::optional<adoption::Reply> reply = frame ? adoption::ReadReply(*frame) : std::nullopt;
  Check(reply && reply->verdict == adoption::Verdict::kAdopted && reply->host_pid == 77 &&
            reply->mint_browser == (1 << 20) + 5 && reply->resize_fence == "fence" && reply->mint_view == 9 &&
            reply->pages == std::vector<adoption::AdoptedPage>{GoldenPage()},
        "adopted, with the host's pid, mint floors, fence and the pages cmux may take back");
  run.Join();
  Check(run.outcomes.size() == 1 && run.outcomes[0].kind == adoption::Listener::Outcome::Kind::kAdopted &&
            run.outcomes[0].app_pid == getpid(),
        "the listener hands over the connection once");
  struct stat info;
  Check(lstat(run.path.c_str(), &info) != 0, "the socket file goes once adopted");
  if (run.outcomes.empty()) return;
  // The connection is the control stream from here: the next bytes reach the client unchanged.
  const char hello[] = "HELLO";
  Check(write(run.outcomes[0].fd, hello, 5) == 5, "the host writes on the adopted connection");
  char got[6] = {0};
  Check(recv(client.fd, got, 5, MSG_WAITALL) == 5 && std::string(got) == "HELLO",
        "the client reads the control stream right after the reply");
}

static void TestListenerMismatch() {
  ListenerRun run(std::chrono::seconds(10), 0, {GoldenPage()});
  Client client(run.path);
  adoption::Offer newer = OfferOfThisProcess();
  newer.wire_id = "w2";
  client.Send(adoption::EncodeOffer(newer));
  const std::optional<control::Message> frame = client.Read();
  const std::optional<adoption::Reply> reply = frame ? adoption::ReadReply(*frame) : std::nullopt;
  Check(reply && reply->verdict == adoption::Verdict::kVersionMismatch && reply->pages.empty(),
        "another wire is answered as a mismatch, with no pages");
  run.Join();
  Check(run.outcomes.size() == 1 && run.outcomes[0].kind == adoption::Listener::Outcome::Kind::kVersionMismatch &&
            run.outcomes[0].fd < 0,
        "a mismatch ends the wait with no connection: the host saves its pages and quits");
}

static void TestListenerMalformedThenExpires() {
  ListenerRun run(std::chrono::milliseconds(1500));
  {
    Client client(run.path);
    adoption::Offer other = OfferOfThisProcess();
    other.app_pid = getpid() + 1;  // names a process other than the peer
    client.Send(adoption::EncodeOffer(other));
    const std::optional<control::Message> frame = client.Read();
    const std::optional<adoption::Reply> reply = frame ? adoption::ReadReply(*frame) : std::nullopt;
    Check(reply && reply->verdict == adoption::Verdict::kMalformed, "an offer for another pid is malformed");
  }
  {
    Client silent(run.path);  // says nothing: at the read limit it is answered as malformed and closed
    const std::optional<control::Message> frame = silent.Read();
    const std::optional<adoption::Reply> reply = frame ? adoption::ReadReply(*frame) : std::nullopt;
    Check(reply && reply->verdict == adoption::Verdict::kMalformed, "a silent client is refused at the read limit");
  }
  run.Join();
  Check(run.outcomes.size() == 1 && run.outcomes[0].kind == adoption::Listener::Outcome::Kind::kExpired,
        "with no adoption the wait ends at the grace deadline");
  struct stat info;
  Check(lstat(run.path.c_str(), &info) != 0, "the socket file goes at the deadline");
}

static void TestKeepsPages() {
  using control::End;
  Check(adoption::KeepsPages(End::kPeerClosed, true, true, false), "EOF from a crashed cmux keeps the pages");
  Check(adoption::KeepsPages(End::kIoError, true, true, false), "a reset socket keeps the pages");
  Check(!adoption::KeepsPages(End::kPeerClosed, false, true, false), "without the switch the host ends at EOF");
  Check(!adoption::KeepsPages(End::kPeerClosed, true, false, false), "a host that never initialized (or quits) ends");
  Check(!adoption::KeepsPages(End::kPeerClosed, true, true, true),
        "EOF after cmux's close-all (a quit whose close wait ran out) is a quit: no orphan");
  Check(!adoption::KeepsPages(End::kIoError, true, true, true), "so is a reset after it");
  Check(!adoption::KeepsPages(End::kMalformed, true, true, false), "a bad frame ends the host");
  Check(!adoption::KeepsPages(End::kQuotaCeiling, true, true, false), "the quota ceiling ends the host");
  Check(!adoption::KeepsPages(End::kClosed, true, true, false), "the host's own close ends it");
}

static void TestAfterOutcome() {
  using Kind = adoption::Listener::Outcome::Kind;
  auto of = [](Kind kind) {
    adoption::Listener::Outcome outcome;
    outcome.kind = kind;
    return outcome;
  };
  Check(adoption::AfterOutcome(of(Kind::kAdopted), true, true) == adoption::Next::kReattach, "an adoption reattaches");
  Check(adoption::AfterOutcome(of(Kind::kAdopted), true, false) == adoption::Next::kQuit,
        "an adoption after a quit began quits");
  Check(adoption::AfterOutcome(of(Kind::kAdopted), false, true) == adoption::Next::kQuit, "no orphan, no reattach");
  for (Kind kind : {Kind::kVersionMismatch, Kind::kExpired, Kind::kFailed, Kind::kUntrusting}) {
    Check(adoption::AfterOutcome(of(kind), true, true) == adoption::Next::kQuit, "every other outcome quits");
  }
}

// A host with no team trusts no peer: it never listens, and its outcome makes it quit.
static void TestListenerUntrusting() {
  ListenerRun run(std::chrono::seconds(10), 0, {}, /*trusts_any_peer=*/false);
  run.Join();
  Check(run.outcomes.size() == 1 && run.outcomes[0].kind == adoption::Listener::Outcome::Kind::kUntrusting,
        "a host that trusts no peer ends its wait at once");
  struct stat info;
  Check(lstat(run.path.c_str(), &info) != 0, "it made no socket");
  if (run.outcomes.size() == 1) {
    Check(adoption::AfterOutcome(run.outcomes[0], true, true) == adoption::Next::kQuit, "and quits");
  }
}

// A relaunched cmux of another version (or with crash survival off) offers: the host answers the mismatch,
// its wait ends, and it quits as at a quit: the quit deadline is armed first (the process ends within
// kQuitLimitSeconds whatever Chromium does), then every page closes, so Chromium writes its profile and each
// tab's history, and the message loop ends after the last page closed.
static void TestMismatchQuitsTheHost() {
  ListenerRun run(std::chrono::seconds(10), 0, {GoldenPage()});
  {
    Client client(run.path);
    adoption::Offer older = OfferOfThisProcess();
    older.wire_id = "w0";
    client.Send(adoption::EncodeOffer(older));
    client.Read();
  }
  run.Join();
  Check(run.outcomes.size() == 1 && run.outcomes[0].kind == adoption::Listener::Outcome::Kind::kVersionMismatch,
        "the mismatch ends the wait");
  if (run.outcomes.size() != 1) return;
  std::vector<std::string> steps;
  int live = 2;
  cmux_host::HostQuit quit(cmux_host::HostQuit::Steps{
      [&] { steps.push_back("deadline " + std::to_string(cmux_host::kQuitLimitSeconds) + " s"); },
      [&] { steps.push_back("stop before start"); }, [&] { steps.push_back("close all"); }, [&] { return live; },
      [&] { steps.push_back("quit loop"); }});
  quit.set_running();
  Check(adoption::AfterOutcome(run.outcomes[0], true, quit.serving()) == adoption::Next::kQuit, "a mismatch quits");
  quit.Quit();
  Check(steps == std::vector<std::string>{"deadline 15 s", "close all"}, "the quit limit is armed before every page closes");
  Check(!quit.serving() && !quit.loop_quit(), "quitting: the loop runs until the pages closed");
  live = 1;
  quit.BrowserClosed();
  Check(!quit.loop_quit(), "one page still open");
  live = 0;
  quit.BrowserClosed();
  Check(quit.loop_quit() && steps.back() == "quit loop", "the loop ends after the last page closed");
  const size_t before = steps.size();
  quit.Quit();
  Check(steps.size() == before + 1 && steps.back() == "deadline 15 s", "a second quit closes nothing again");
}

int main() {
  TestGoldenOffer();
  TestReadOfferRefusesOtherFrames();
  TestJudge();
  TestReply();
  TestFitReplyPages();
  TestSocketPath();
  TestListen();
  TestKeepsPages();
  TestAfterOutcome();
  TestListenerAdopts();
  TestListenerMismatch();
  TestListenerMalformedThenExpires();
  TestListenerUntrusting();
  TestMismatchQuitsTheHost();
  if (failures != 0) {
    std::fprintf(stderr, "host_adoption_test: %d failures\n", failures);
    return 1;
  }
  std::printf("host_adoption_test: ok\n");
  return 0;
}
