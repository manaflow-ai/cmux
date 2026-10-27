// See host_adoption.h. POSIX only: no CEF, no AppKit.
#include "host_adoption.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#if defined(__APPLE__)
#include <pthread.h>
#include <pthread/qos.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <deque>
#include <thread>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host::adoption {

namespace {

using control::TlvReader;
using control::TlvWriter;

#if defined(MSG_NOSIGNAL)
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;  // the host ignores SIGPIPE (browser_host_main.mm)
#endif

control::Message MessageOf(uint16_t op, std::vector<control::Field> fields) {
  control::Message message;
  message.op = op;
  message.fields = std::move(fields);
  return message;
}

// The short path's directory: this user's, mode 0700, made when missing.
bool PrivateDirectory(const std::string& directory) {
  if (mkdir(directory.c_str(), 0700) != 0 && errno != EEXIST) return false;
  struct stat info;
  if (lstat(directory.c_str(), &info) != 0) return false;
  if (!S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) {
    errno = EPERM;
    return false;
  }
  return true;
}

std::string DirectoryOf(const std::string& path) {
  const size_t slash = path.rfind('/');
  return slash == std::string::npos ? std::string() : path.substr(0, slash);
}

}  // namespace

std::optional<FrameworkIdentity> IdentityOf(const std::string& binary) {
  struct stat info;
  if (binary.empty() || stat(binary.c_str(), &info) != 0) return std::nullopt;
  FrameworkIdentity identity;
  identity.device = static_cast<int64_t>(info.st_dev);
  identity.inode = static_cast<int64_t>(info.st_ino);
  identity.size = static_cast<int64_t>(info.st_size);
  identity.mtime = static_cast<int64_t>(info.st_mtime);
  return identity;
}

control::Message EncodeOffer(const Offer& offer) {
  TlvWriter w;
  w.Str(offer.wire_id.c_str());
  w.Str(offer.abi_id.c_str());
  w.I32(offer.min_fork_api);
  w.I64(offer.framework.device);
  w.I64(offer.framework.inode);
  w.I64(offer.framework.size);
  w.I64(offer.framework.mtime);
  w.I32(offer.app_pid);
  return MessageOf(kOpAdopt, w.Take());
}

std::optional<Offer> ReadOffer(const control::Message& message) {
  if (message.op != kOpAdopt || message.reply || !message.fds.empty() || message.ctl_seq != 0) return std::nullopt;
  TlvReader r(message.fields);
  Offer offer;
  const std::optional<std::string> wire = r.Str();
  const std::optional<std::string> abi = r.Str();
  offer.min_fork_api = r.I32();
  offer.framework.device = r.I64();
  offer.framework.inode = r.I64();
  offer.framework.size = r.I64();
  offer.framework.mtime = r.I64();
  offer.app_pid = r.I32();
  if (!r.ok() || !r.AtEnd() || !wire || !abi || offer.app_pid <= 1) return std::nullopt;
  offer.wire_id = *wire;
  offer.abi_id = *abi;
  return offer;
}

Verdict Judge(const std::optional<Offer>& offer, const HostVersions& host) {
  if (!offer) return Verdict::kMalformed;
  const bool same = offer->wire_id == host.wire_id && offer->abi_id == host.abi_id &&
                    offer->framework == host.framework && host.fork_api >= offer->min_fork_api;
  return same ? Verdict::kAdopted : Verdict::kVersionMismatch;
}

control::Message EncodeReply(const Reply& reply) {
  TlvWriter w;
  w.I32(static_cast<int32_t>(reply.verdict));
  w.I32(reply.host_pid);
  w.I32(reply.fork_api);
  w.I32(reply.mint_browser);
  w.I32(reply.mint_devtools);
  w.Str(reply.resize_fence.c_str());
  w.I64(static_cast<int64_t>(reply.mint_view));
  for (const AdoptedPage& page : reply.pages) {
    w.I32(page.browser);
    w.I32(page.window);
    w.I64(static_cast<int64_t>(page.view));
    w.U32(page.context);
    w.Str(page.key.c_str());
  }
  return MessageOf(kOpAdoptReply, w.Take());
}

std::optional<Reply> ReadReply(const control::Message& message) {
  if (message.op != kOpAdoptReply || message.reply || !message.fds.empty()) return std::nullopt;
  TlvReader r(message.fields);
  Reply reply;
  const int32_t verdict = r.I32();
  reply.host_pid = r.I32();
  reply.fork_api = r.I32();
  reply.mint_browser = r.I32();
  reply.mint_devtools = r.I32();
  const std::optional<std::string> fence = r.Str();
  reply.mint_view = static_cast<uint64_t>(r.I64());
  if (!r.ok() || !fence || verdict < 0 || verdict > static_cast<int32_t>(Verdict::kMalformed)) return std::nullopt;
  while (!r.AtEnd()) {
    AdoptedPage page;
    page.browser = r.I32();
    page.window = r.I32();
    page.view = static_cast<uint64_t>(r.I64());
    page.context = r.U32();
    const std::optional<std::string> key = r.Str();
    if (!r.ok() || !key || key->empty() || key->size() > kMaxPageKeyBytes) return std::nullopt;
    page.key = *key;
    reply.pages.push_back(std::move(page));
  }
  if (!reply.pages.empty() && static_cast<Verdict>(verdict) != Verdict::kAdopted) return std::nullopt;
  reply.verdict = static_cast<Verdict>(verdict);
  reply.resize_fence = *fence;
  return reply;
}

std::vector<AdoptedPage> FitReplyPages(const Reply& reply, std::vector<AdoptedPage> pages) {
  // A frame body's bytes: each field's header and payload (chromium_host_control.h).
  auto body_of = [](const std::vector<control::Field>& fields) {
    size_t size = 0;
    for (const control::Field& field : fields) {
      const size_t payload = field.type == control::Type::kI32                                          ? 4
                             : field.type == control::Type::kI64 || field.type == control::Type::kF64 ? 8
                                                                                                       : field.bytes.size();
      size += control::kFieldHeaderSize + payload;
    }
    return size;
  };
  Reply bare = reply;
  bare.pages.clear();
  size_t body = body_of(EncodeReply(bare).fields);
  std::vector<AdoptedPage> fit;
  for (AdoptedPage& page : pages) {
    if (page.key.empty() || page.key.size() > kMaxPageKeyBytes) continue;
    // i32 browser, i32 window, i64 view, i32 context, str key.
    const size_t size = 5 * control::kFieldHeaderSize + 4 + 4 + 8 + 4 + page.key.size();
    if (body + size > control::kMaxBody) break;
    body += size;
    fit.push_back(std::move(page));
  }
  return fit;
}

uint64_t Fnv1a64(const std::string& text) {
  uint64_t hash = 0xcbf29ce484222325ull;
  for (unsigned char byte : text) {
    hash ^= byte;
    hash *= 0x100000001b3ull;
  }
  return hash;
}

std::string ShortSocketDirectory(uid_t uid) {
  return "/tmp/cmux-chromium-host-" + std::to_string(uid);
}

std::string ShortSocketPath(const std::string& root_cache, uid_t uid) {
  char name[32];
  std::snprintf(name, sizeof name, "%016llx", static_cast<unsigned long long>(Fnv1a64(root_cache)));
  return ShortSocketDirectory(uid) + "/" + name + ".sock";
}

std::string SocketPath(const std::string& root_cache, uid_t uid) {
  if (root_cache.empty()) return std::string();
  std::string path = root_cache;
  while (path.size() > 1 && path.back() == '/') path.pop_back();
  path += "/";
  path += kSocketName;
  return path.size() <= kMaxSocketPathBytes ? path : ShortSocketPath(root_cache, uid);
}

int Listen(const std::string& path) {
  sockaddr_un address{};
  if (path.empty() || path.size() >= sizeof address.sun_path) {
    errno = ENAMETOOLONG;
    return -1;
  }
  const std::string directory = DirectoryOf(path);
  if (path.rfind(ShortSocketDirectory(geteuid()) + "/", 0) == 0 && !PrivateDirectory(directory)) return -1;
  struct stat existing;
  if (lstat(path.c_str(), &existing) == 0) {
    if (!S_ISSOCK(existing.st_mode)) {
      errno = EEXIST;
      return -1;
    }
    unlink(path.c_str());  // a socket a host before this one left
  }
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || fcntl(fd, F_SETFL, O_NONBLOCK) != 0) {
    const int error = errno;
    close(fd);
    errno = error;
    return -1;
  }
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  // The file takes the umask's mode at bind; chmod narrows it at once. Its
  // directory is this user's, and every peer's code signature is checked.
  if (bind(fd, reinterpret_cast<const sockaddr*>(&address), sizeof address) != 0 ||
      chmod(path.c_str(), 0600) != 0 || listen(fd, 4) != 0) {
    const int error = errno;
    close(fd);
    unlink(path.c_str());
    errno = error;
    return -1;
  }
  return fd;
}

void Unlisten(const std::string& path) {
  struct stat existing;
  if (!path.empty() && lstat(path.c_str(), &existing) == 0 && S_ISSOCK(existing.st_mode)) unlink(path.c_str());
}

namespace {

void SetTimeouts(int fd, std::chrono::milliseconds limit) {
  timeval tv{};
  tv.tv_sec = static_cast<time_t>(limit.count() / 1000);
  tv.tv_usec = static_cast<suseconds_t>((limit.count() % 1000) * 1000);
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

bool ReadExactly(int fd, uint8_t* out, size_t size) {
  size_t got = 0;
  while (got < size) {
    const ssize_t n = read(fd, out + got, size - got);
    if (n > 0) {
      got += static_cast<size_t>(n);
    } else if (n < 0 && errno == EINTR) {
      continue;
    } else {
      return false;  // EOF, the read limit or an error
    }
  }
  return true;
}

bool WriteAll(int fd, const std::vector<uint8_t>& bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
    const ssize_t n = send(fd, bytes.data() + sent, bytes.size() - sent, kSendFlags);
    if (n > 0) {
      sent += static_cast<size_t>(n);
    } else if (n < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }
  return true;
}

// One whole frame with no descriptors, read to its last byte and no further:
// what follows on the socket is the control stream's.
std::optional<control::Message> ReadFrame(int fd) {
  std::vector<uint8_t> bytes(control::kHeaderSize);
  if (!ReadExactly(fd, bytes.data(), bytes.size())) return std::nullopt;
  const uint32_t length = static_cast<uint32_t>(bytes[0]) | static_cast<uint32_t>(bytes[1]) << 8 |
                          static_cast<uint32_t>(bytes[2]) << 16 | static_cast<uint32_t>(bytes[3]) << 24;
  if (length > control::kMaxBody) return std::nullopt;
  bytes.resize(control::kHeaderSize + length);
  if (!ReadExactly(fd, bytes.data() + control::kHeaderSize, length)) return std::nullopt;
  std::deque<int> fds;
  control::Message message;
  size_t consumed = 0;
  if (control::Decode(bytes.data(), bytes.size(), &fds, &message, &consumed) != control::Parse::kFrame ||
      consumed != bytes.size()) {
    return std::nullopt;
  }
  return message;
}

int64_t MillisUntil(std::chrono::steady_clock::time_point deadline) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
}

}  // namespace

void Listener::Start(Options options) {
  std::thread([options = std::move(options)]() mutable {
#if defined(__APPLE__)
    pthread_setname_np("com.cmuxterm.chromium-host.adoption");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    Run(std::move(options));
  }).detach();
}

void Listener::Run(Options options) {
  if (options.trusts_any_peer && !options.trusts_any_peer()) {
    Outcome untrusting;
    untrusting.kind = Outcome::Kind::kUntrusting;
    options.done(untrusting);
    return;
  }
  const int listener = Listen(options.path);
  if (listener < 0) {
    Outcome failed;
    failed.error = errno;
    options.done(failed);
    return;
  }
  auto finish = [&](Outcome outcome) {
    close(listener);
    Unlisten(options.path);
    options.done(outcome);
  };
  const auto deadline = std::chrono::steady_clock::now() + options.grace;
  for (;;) {
    const int64_t remaining = MillisUntil(deadline);
    if (remaining <= 0) {
      Outcome expired;
      expired.kind = Outcome::Kind::kExpired;
      return finish(expired);
    }
    pollfd ready{listener, POLLIN, 0};
    // wakeup-allow: deadline the orphan's one grace deadline (30 s), only while cmux is gone; the host ends at it
    const int polled = poll(&ready, 1, static_cast<int>(remaining));
    if (polled <= 0) continue;  // the deadline, EINTR: checked at the top
    const int fd = accept(listener, nullptr, nullptr);
    if (fd < 0) continue;
    // A listener's O_NONBLOCK may pass to the accepted socket (BSD): the exchange blocks, with limits.
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    SetTimeouts(fd, options.read_limit);
    const std::optional<pid_t> peer = options.check_peer(fd);
    if (!peer) {
      close(fd);  // not this user's cmux: nothing is read from it
      continue;
    }
    std::optional<control::Message> frame = ReadFrame(fd);
    std::optional<Offer> offer = frame ? ReadOffer(*frame) : std::nullopt;
    if (offer && offer->app_pid != *peer) offer.reset();  // the offer names another process
    Reply reply = options.reply;
    reply.verdict = Judge(offer, options.versions);
    if (reply.verdict != Verdict::kAdopted) reply.pages.clear();  // only the adopting cmux learns the pages
    std::vector<uint8_t> bytes;
    const bool answered = control::Encode(EncodeReply(reply), &bytes) && WriteAll(fd, bytes);
    if (!answered || reply.verdict == Verdict::kMalformed) {
      close(fd);
      continue;
    }
    if (reply.verdict == Verdict::kVersionMismatch) {
      close(fd);
      Outcome mismatch;
      mismatch.kind = Outcome::Kind::kVersionMismatch;
      return finish(mismatch);
    }
    SetTimeouts(fd, std::chrono::milliseconds(0));  // the control channel sets its own mode
    Outcome adopted;
    adopted.kind = Outcome::Kind::kAdopted;
    adopted.fd = fd;
    adopted.app_pid = *peer;
    return finish(adopted);
  }
}

bool KeepsPages(control::End end, bool survives, bool running, bool quit_began) {
  if (!survives || !running || quit_began) return false;
  return end == control::End::kPeerClosed || end == control::End::kIoError;
}

Next AfterOutcome(const Listener::Outcome& outcome, bool orphaned, bool serving) {
  return outcome.kind == Listener::Outcome::Kind::kAdopted && orphaned && serving ? Next::kReattach : Next::kQuit;
}

}  // namespace cmux_host::adoption
