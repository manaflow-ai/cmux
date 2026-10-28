// The Chromium Host's provider link (host_provider_link.h):
// the socket to the browser host, its dial and its two
// threads. The UI thread only hands frames over and gets batches back, so a
// thousand CDP messages a second cost it one task per batch and no wait.
//
// Threads (plans/cmux-next/threading-model.md, "Chromium"):
//   chromium-host.provider-link.read   dials, checks the peer (its pid,
//                                      then its code signature), says
//                                      relay.hello, then waits only in read(2)
//   chromium-host.provider-link.write  waits for frames to send, then in write(2)
// Both are user-initiated, as the control channel's reader is. Bounds: frames
// read and not run yet stop the reader at kInboxLimit until the UI thread
// drains them; bytes waiting to be written over kOutboxBytesLimit end the
// link (the browser host reads it as closed, and relays through cmux again).
//
// Plain C++ and POSIX, no CEF and no AppKit (the tests build it on Linux).

#include "host_provider_link.h"

#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>


namespace cmux_host {

namespace {

constexpr size_t kInboxLimit = 4096;
constexpr size_t kOutboxBytesLimit = size_t{64} << 20;
constexpr int kAckTimeoutSeconds = 5;

void NameThread(const char* name) {
#if defined(__APPLE__)
  pthread_setname_np(name);
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#else
  pthread_setname_np(pthread_self(), name);
#endif
}

bool WriteAll(int fd, const std::string& bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
#if defined(MSG_NOSIGNAL)
    const ssize_t n = ::send(fd, bytes.data() + sent, bytes.size() - sent, MSG_NOSIGNAL);
#else
    const ssize_t n = ::send(fd, bytes.data() + sent, bytes.size() - sent, 0);
#endif
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    sent += static_cast<size_t>(n);
  }
  return true;
}

bool ReadAll(int fd, char* out, size_t size) {
  size_t got = 0;
  while (got < size) {
    const ssize_t n = ::read(fd, out + got, size - got);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    got += static_cast<size_t>(n);
  }
  return true;
}

// One frame's JSON; nullopt at the end of the stream or on a bad length.
std::optional<std::string> ReadFrame(int fd) {
  unsigned char header[4];
  if (!ReadAll(fd, reinterpret_cast<char*>(header), sizeof header)) return std::nullopt;
  const size_t length = (size_t{header[0]} << 24) | (size_t{header[1]} << 16) | (size_t{header[2]} << 8) | header[3];
  if (length > kMaxRelayFrame) return std::nullopt;
  std::string body(length, '\0');
  if (length > 0 && !ReadAll(fd, body.data(), length)) return std::nullopt;
  return body;
}

}  // namespace

// The peer process of a connected Unix socket: the process that holds the
// listening end (macOS LOCAL_PEERPID, Linux SO_PEERCRED); 0 when unknown.
int32_t ProviderLinkPeerPid(int fd) {
#if defined(__APPLE__)
  pid_t pid = 0;
  socklen_t length = sizeof pid;
  if (::getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0) return 0;
  return static_cast<int32_t>(pid);
#elif defined(SO_PEERCRED)
  struct ucred cred = {};
  socklen_t length = sizeof cred;
  if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) != 0) return 0;
  return static_cast<int32_t>(cred.pid);
#else
  (void)fd;
  return 0;
#endif
}

bool ProviderLinkAcceptsPeer(const ProviderLinkConfig& config, int32_t peer) {
  // The daemon holds the socket under activation, the browser host otherwise
  // (the app's ProviderCredentials.acceptsPeer): either, and no other.
  if (config.host_pid <= 0 && config.listener_pid <= 0) return true;
  return peer > 0 && (peer == config.host_pid || peer == config.listener_pid);
}

// One connection: its socket and the state its threads share with the UI
// thread. Freed when the link and both threads let go of it.
struct ProviderLink::Session {
  explicit Session(uint64_t generation) : generation(generation) {}
  ~Session() {
    if (fd >= 0) ::close(fd);
  }

  const uint64_t generation;
  int fd = -1;
  std::mutex mutex;
  std::condition_variable outbox_ready;
  std::condition_variable inbox_drained;
  std::deque<std::string> outbox;  // frame bytes
  size_t outbox_bytes = 0;
  std::deque<RelayFrame> inbox;
  bool closed = false;
  bool connected = false;  // relay.hello.ack came

  // Under `mutex`.
  void CloseLocked() {
    if (closed) return;
    closed = true;
    if (fd >= 0) ::shutdown(fd, SHUT_RDWR);
    outbox_ready.notify_all();
    inbox_drained.notify_all();
  }
};

ProviderLink::ProviderLink(Post post_main, OnFrames on_frames, OnEnd on_end, PeerSigned peer_signed)
    : post_main_(std::move(post_main)),
      on_frames_(std::move(on_frames)),
      on_end_(std::move(on_end)),
      peer_signed_(std::move(peer_signed)) {}

ProviderLink::~ProviderLink() {
  Close();
}

bool ProviderLink::Dials(const ProviderLinkConfig& config) const {
  return session_ != nullptr && config_ == config;
}

void ProviderLink::Connect(const ProviderLinkConfig& config) {
  // A link that runs or dials for the same browser host stays: cmux sends
  // the op again to a host it adopted, or when nothing changed.
  if (Dials(config)) return;
  Close();
  config_ = config;
  if (!config.socket) return;
  auto session = std::make_shared<Session>(++generation_);
  session_ = session;
  const ProviderLinkConfig dial = config;
  // Each thread holds the session and nothing of `this`: what reaches the UI
  // thread is posted with the generation, which a later Connect or Close
  // makes stale.
  std::thread([this_link = this, session, dial, post = post_main_, peer_signed = peer_signed_] {
    NameThread("chromium-host.provider-link.read");
    ReadLoop(this_link, session, dial, post, peer_signed);
  }).detach();
  std::thread([session] {
    NameThread("chromium-host.provider-link.write");
    WriteLoop(session);
  }).detach();
}

void ProviderLink::Close() {
  std::shared_ptr<Session> session = std::move(session_);
  session_.reset();
  if (!session) return;
  std::lock_guard<std::mutex> lock(session->mutex);
  session->CloseLocked();
}

bool ProviderLink::connected() const {
  if (!session_) return false;
  std::lock_guard<std::mutex> lock(session_->mutex);
  return session_->connected && !session_->closed;
}

void ProviderLink::Write(std::string json) {
  std::shared_ptr<Session> session = session_;
  if (!session) return;
  std::string bytes = RelayFrameBytes(json);
  std::lock_guard<std::mutex> lock(session->mutex);
  if (session->closed) return;
  if (session->outbox_bytes + bytes.size() > kOutboxBytesLimit) {
    // The browser host stopped reading: the link ends, and it relays
    // through cmux again (direct_relay.rs link_closed).
    session->CloseLocked();
    return;
  }
  session->outbox_bytes += bytes.size();
  session->outbox.push_back(std::move(bytes));
  session->outbox_ready.notify_one();
}

// The next frame to write, after waiting for one (no timeout: a frame or the link's end wakes it);
// false once the link closed.
bool ProviderLink::NextOutbound(Session& session, std::string* bytes) {
  std::unique_lock<std::mutex> lock(session.mutex);
  session.outbox_ready.wait(lock, [&] { return session.closed || (session.connected && !session.outbox.empty()); });
  if (session.closed) return false;
  *bytes = std::move(session.outbox.front());
  session.outbox.pop_front();
  session.outbox_bytes -= bytes->size();
  return true;
}

void ProviderLink::WriteLoop(std::shared_ptr<Session> session) {
  std::string bytes;
  while (NextOutbound(*session, &bytes)) {
    if (!WriteAll(session->fd, bytes)) {
      std::lock_guard<std::mutex> lock(session->mutex);
      session->CloseLocked();
      return;
    }
  }
}

void ProviderLink::ReadLoop(ProviderLink* link, std::shared_ptr<Session> session, ProviderLinkConfig dial,
                            Post post, PeerSigned peer_signed) {
  const uint64_t generation = session->generation;
  auto ended = [&] {
    {
      std::lock_guard<std::mutex> lock(session->mutex);
      session->CloseLocked();
    }
    post([link, generation] { link->Ended(generation); });
  };
  const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return ended();
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    session->fd = fd;
    if (session->closed) {
      ::shutdown(fd, SHUT_RDWR);
      return;
    }
  }
  ::fcntl(fd, F_SETFD, FD_CLOEXEC);
#if defined(SO_NOSIGPIPE)
  int one = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  sockaddr_un address = {};
  address.sun_family = AF_UNIX;
  if (dial.socket->size() >= sizeof address.sun_path) return ended();
  std::memcpy(address.sun_path, dial.socket->c_str(), dial.socket->size() + 1);
  if (::connect(fd, reinterpret_cast<const sockaddr*>(&address), sizeof address) != 0) return ended();
  // The browser host proves itself before the credential leaves: a same-uid
  // process that took the socket path first gets nothing, and neither does a
  // process that is not signed as this cmux.
  if (!ProviderLinkAcceptsPeer(dial, ProviderLinkPeerPid(fd))) return ended();
  if (!peer_signed || !peer_signed(fd)) return ended();
  if (!WriteAll(fd, RelayFrameBytes(EncodeRelayHello(dial.link_id, dial.credential)))) {
    return ended();
  }
  timeval timeout = {kAckTimeoutSeconds, 0};
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  std::optional<std::string> ack = ReadFrame(fd);
  std::optional<RelayFrame> ack_frame = ack ? DecodeRelayFrame(*ack) : std::nullopt;
  if (!ack_frame || ack_frame->kind != RelayFrame::Kind::kHelloAck) return ended();
  timeout = {0, 0};
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    session->connected = true;
    session->outbox_ready.notify_all();
  }
  while (std::optional<std::string> json = ReadFrame(fd)) {
    std::optional<RelayFrame> frame = DecodeRelayFrame(*json);
    if (!frame) break;  // a malformed frame ends the link, as on the control channel
    if (frame->kind == RelayFrame::Kind::kOther || frame->kind == RelayFrame::Kind::kHelloAck) continue;
    std::unique_lock<std::mutex> lock(session->mutex);
    session->inbox_drained.wait(lock, [&] { return session->closed || session->inbox.size() < kInboxLimit; });
    if (session->closed) return;
    const bool first = session->inbox.empty();
    session->inbox.push_back(std::move(*frame));
    lock.unlock();
    // One UI task per batch: frames that arrive while it waits join it.
    if (first) post([link, generation] { link->Drain(generation); });
  }
  ended();
}

void ProviderLink::Drain(uint64_t generation) {
  std::shared_ptr<Session> session = session_;
  if (!session || session->generation != generation) return;
  std::vector<RelayFrame> batch;
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    batch.assign(std::make_move_iterator(session->inbox.begin()), std::make_move_iterator(session->inbox.end()));
    session->inbox.clear();
    session->inbox_drained.notify_all();
  }
  on_frames_(std::move(batch));
}

void ProviderLink::Ended(uint64_t generation) {
  if (!session_ || session_->generation != generation) return;
  session_.reset();
  on_end_();
}

}  // namespace cmux_host
