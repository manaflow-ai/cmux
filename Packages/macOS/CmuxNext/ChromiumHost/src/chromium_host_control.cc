// The control channel (chromium_host_control.h).
#include "chromium_host_control.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>

#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

namespace cmux_host::control {

namespace {

void Put16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value));
  out->push_back(static_cast<uint8_t>(value >> 8));
}

void Put32(std::vector<uint8_t>* out, uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<uint8_t>(value >> (8 * i)));
}

void Put64(std::vector<uint8_t>* out, uint64_t value) {
  for (int i = 0; i < 8; ++i) out->push_back(static_cast<uint8_t>(value >> (8 * i)));
}

uint64_t GetLE(const uint8_t* in, size_t count) {
  uint64_t value = 0;
  for (size_t i = 0; i < count; ++i) value |= static_cast<uint64_t>(in[i]) << (8 * i);
  return value;
}

void CloseAll(std::deque<int>* fds) {
  for (int fd : *fds) ::close(fd);
  fds->clear();
}

}  // namespace

Field Field::I32(uint8_t tag, int32_t value) {
  Field field;
  field.tag = tag;
  field.type = Type::kI32;
  field.integer = value;
  return field;
}

Field Field::I64(uint8_t tag, int64_t value) {
  Field field;
  field.tag = tag;
  field.type = Type::kI64;
  field.integer = value;
  return field;
}

Field Field::F64(uint8_t tag, double value) {
  Field field;
  field.tag = tag;
  field.type = Type::kF64;
  field.real = value;
  return field;
}

Field Field::Bytes(uint8_t tag, std::string value) {
  Field field;
  field.tag = tag;
  field.type = Type::kBytes;
  field.bytes = std::move(value);
  return field;
}

Field Field::Str(uint8_t tag, std::string value) {
  Field field = Bytes(tag, std::move(value));
  field.type = Type::kStr;
  return field;
}

bool Field::operator==(const Field& other) const {
  if (tag != other.tag || type != other.type) return false;
  switch (type) {
    case Type::kI32:
    case Type::kI64:
      return integer == other.integer;
    case Type::kF64:
      return std::memcmp(&real, &other.real, sizeof real) == 0;
    case Type::kBytes:
    case Type::kStr:
      return bytes == other.bytes;
  }
  return false;
}

const Field* Message::Find(uint8_t tag) const {
  for (const Field& field : fields) {
    if (field.tag == tag) return &field;
  }
  return nullptr;
}

bool IsValidUtf8(const std::string& text) {
  const auto* bytes = reinterpret_cast<const uint8_t*>(text.data());
  size_t i = 0, n = text.size();
  while (i < n) {
    const uint8_t lead = bytes[i];
    size_t extra;
    uint32_t point;
    if (lead < 0x80) {
      ++i;
      continue;
    } else if ((lead & 0xe0) == 0xc0) {
      extra = 1;
      point = lead & 0x1f;
    } else if ((lead & 0xf0) == 0xe0) {
      extra = 2;
      point = lead & 0x0f;
    } else if ((lead & 0xf8) == 0xf0) {
      extra = 3;
      point = lead & 0x07;
    } else {
      return false;
    }
    if (n - i <= extra) return false;
    for (size_t k = 1; k <= extra; ++k) {
      if ((bytes[i + k] & 0xc0) != 0x80) return false;
      point = (point << 6) | (bytes[i + k] & 0x3f);
    }
    static constexpr uint32_t kSmallest[] = {0, 0x80, 0x800, 0x10000};
    if (point < kSmallest[extra] || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) return false;
    i += extra + 1;
  }
  return true;
}

bool Encode(const Message& message, std::vector<uint8_t>* out) {
  if (message.fds.size() > kMaxFds) return false;
  std::vector<uint8_t> body;
  for (const Field& field : message.fields) {
    body.push_back(static_cast<uint8_t>(field.type));
    body.push_back(field.tag);
    switch (field.type) {
      case Type::kI32:
        Put16(&body, 4);
        Put32(&body, static_cast<uint32_t>(static_cast<int32_t>(field.integer)));
        break;
      case Type::kI64:
        Put16(&body, 8);
        Put64(&body, static_cast<uint64_t>(field.integer));
        break;
      case Type::kF64: {
        uint64_t bits;
        std::memcpy(&bits, &field.real, sizeof bits);
        Put16(&body, 8);
        Put64(&body, bits);
        break;
      }
      case Type::kStr:
        if (!IsValidUtf8(field.bytes)) return false;
        [[fallthrough]];
      case Type::kBytes:
        if (field.bytes.size() > UINT16_MAX) return false;
        Put16(&body, static_cast<uint16_t>(field.bytes.size()));
        body.insert(body.end(), field.bytes.begin(), field.bytes.end());
        break;
    }
    if (body.size() > kMaxBody) return false;
  }
  const uint16_t flags = static_cast<uint16_t>((message.reply ? kFlagReply : 0) | message.fds.size());
  Put32(out, static_cast<uint32_t>(body.size()));
  Put16(out, message.op);
  Put16(out, flags);
  Put32(out, message.token);
  out->insert(out->end(), body.begin(), body.end());
  return true;
}

Parse Decode(const uint8_t* data, size_t size, std::deque<int>* fds, Message* out, size_t* consumed) {
  if (size < kHeaderSize) return Parse::kNeedMore;
  const uint32_t length = static_cast<uint32_t>(GetLE(data, 4));
  const uint16_t flags = static_cast<uint16_t>(GetLE(data + 6, 2));
  const size_t fd_count = flags & kFdCountMask;
  if (length > kMaxBody || (flags & ~kKnownFlags) != 0 || fd_count > kMaxFds) return Parse::kMalformed;
  if (size < kHeaderSize + length) return Parse::kNeedMore;
  Message message;
  message.op = static_cast<uint16_t>(GetLE(data + 4, 2));
  message.reply = (flags & kFlagReply) != 0;
  message.token = static_cast<uint32_t>(GetLE(data + 8, 4));
  size_t at = kHeaderSize;
  const size_t end = kHeaderSize + length;
  while (at < end) {
    if (end - at < kFieldHeaderSize) return Parse::kMalformed;
    Field field;
    const uint8_t type = data[at];
    field.tag = data[at + 1];
    const size_t field_length = static_cast<size_t>(GetLE(data + at + 2, 2));
    at += kFieldHeaderSize;
    if (field_length > end - at) return Parse::kMalformed;
    const uint8_t* value = data + at;
    switch (type) {
      case static_cast<uint8_t>(Type::kI32):
        if (field_length != 4) return Parse::kMalformed;
        field.type = Type::kI32;
        field.integer = static_cast<int32_t>(static_cast<uint32_t>(GetLE(value, 4)));
        break;
      case static_cast<uint8_t>(Type::kI64):
        if (field_length != 8) return Parse::kMalformed;
        field.type = Type::kI64;
        field.integer = static_cast<int64_t>(GetLE(value, 8));
        break;
      case static_cast<uint8_t>(Type::kF64): {
        if (field_length != 8) return Parse::kMalformed;
        const uint64_t bits = GetLE(value, 8);
        field.type = Type::kF64;
        std::memcpy(&field.real, &bits, sizeof bits);
        break;
      }
      case static_cast<uint8_t>(Type::kBytes):
      case static_cast<uint8_t>(Type::kStr):
        field.type = static_cast<Type>(type);
        field.bytes.assign(reinterpret_cast<const char*>(value), field_length);
        if (field.type == Type::kStr && !IsValidUtf8(field.bytes)) return Parse::kMalformed;
        break;
      default:
        return Parse::kMalformed;
    }
    at += field_length;
    message.fields.push_back(std::move(field));
  }
  if (fds->size() < fd_count) return Parse::kMalformed;
  for (size_t i = 0; i < fd_count; ++i) {
    message.fds.push_back(fds->front());
    fds->pop_front();
  }
  *out = std::move(message);
  *consumed = end;
  return Parse::kFrame;
}

bool PendingFdsFit(const uint8_t* data, size_t size, size_t pending) {
  if (pending == 0) return true;
  if (size == 0) return false;
  if (size < kHeaderSize) return pending <= kMaxFds;
  const uint16_t flags = static_cast<uint16_t>(GetLE(data + 6, 2));
  return pending <= (flags & kFdCountMask);
}

// MARK: Outbox

Outbox::Outbox(size_t quota_bytes, size_t quota_messages) : quota_bytes_(quota_bytes), quota_messages_(quota_messages) {}

Outbox::~Outbox() { Clear(); }

void Outbox::CloseFds(Entry* entry) {
  for (int fd : entry->fds) ::close(fd);
  entry->fds.clear();
}

bool Outbox::Push(std::vector<uint8_t> bytes, std::vector<int> fds, std::optional<uint64_t> key) {
  bool replaced = false;
  if (key) {
    auto found = keyed_.find(*key);
    if (found != keyed_.end()) {
      Entry& waiting = entries_[found->second - removed_];
      if (waiting.offset == 0) {
        Drop(&waiting);
        replaced = true;
      }
      keyed_.erase(found);
    }
  }
  bytes_ += bytes.size();
  ++messages_;
  entries_.push_back(Entry{std::move(bytes), std::move(fds), 0, key, true});
  if (key) keyed_[*key] = removed_ + entries_.size() - 1;
  if (dead_ > 64 && dead_ > messages_) Compact();
  return replaced;
}

Outbox::Entry* Outbox::Front() {
  while (!entries_.empty() && !entries_.front().live) {
    entries_.pop_front();
    ++removed_;
    --dead_;
  }
  return entries_.empty() ? nullptr : &entries_.front();
}

size_t Outbox::Gather(iovec* iov, size_t max, const std::vector<int>** fds) {
  *fds = nullptr;
  size_t count = 0;
  for (Entry& entry : entries_) {
    if (!entry.live) continue;
    if (count == max) break;
    if (count == 0) {
      if (entry.offset == 0 && !entry.fds.empty()) *fds = &entry.fds;
    } else if (!entry.fds.empty()) {
      break;
    }
    iov[count].iov_base = entry.bytes.data() + entry.offset;
    iov[count].iov_len = entry.bytes.size() - entry.offset;
    ++count;
  }
  return count;
}

void Outbox::Advance(size_t written) {
  while (written > 0) {
    Entry* front = Front();
    if (front == nullptr) return;
    if (front->offset == 0) CloseFds(front);
    const size_t left = front->bytes.size() - front->offset;
    if (written < left) {
      front->offset += written;
      return;
    }
    written -= left;
    PopFront();
  }
}

void Outbox::PopFront() {
  Entry* front = Front();
  if (front == nullptr) return;
  if (front->key) {
    auto found = keyed_.find(*front->key);
    if (found != keyed_.end() && found->second == removed_) keyed_.erase(found);
  }
  CloseFds(front);
  bytes_ -= front->bytes.size();
  --messages_;
  entries_.pop_front();
  ++removed_;
}

void Outbox::Clear() {
  for (Entry& entry : entries_) CloseFds(&entry);
  entries_.clear();
  keyed_.clear();
  removed_ = 0;
  dead_ = 0;
  messages_ = 0;
  bytes_ = 0;
}

size_t Outbox::CountKey(uint64_t key) const {
  return static_cast<size_t>(
      std::count_if(entries_.begin(), entries_.end(),
                    [key](const Entry& e) { return e.live && e.offset == 0 && e.key == key; }));
}

void Outbox::Drop(Entry* entry) {
  CloseFds(entry);
  bytes_ -= entry->bytes.size();
  std::vector<uint8_t>().swap(entry->bytes);
  entry->live = false;
  --messages_;
  ++dead_;
}

void Outbox::Compact() {
  std::deque<Entry> kept;
  keyed_.clear();
  for (Entry& entry : entries_) {
    if (!entry.live) continue;
    if (entry.key) keyed_[*entry.key] = kept.size();
    kept.push_back(std::move(entry));
  }
  entries_.swap(kept);
  removed_ = 0;
  dead_ = 0;
}

// MARK: Channel

struct Channel::Core : std::enable_shared_from_this<Core> {
  Core(int socket_fd, Post post, OnMessages on_messages, OnEnd on_end, Options options)
      : post(std::move(post)),
        on_messages(std::move(on_messages)),
        on_end(std::move(on_end)),
        options(options),
        fd(socket_fd),
        outbox(options.quota_bytes, options.quota_messages) {}

  // Messages a detached channel never delivered: their descriptors are ours.
  ~Core() {
    for (Message& message : inbox) {
      for (int received : message.fds) ::close(received);
    }
  }

  const Post post;
  const OnMessages on_messages;
  const OnEnd on_end;
  const Options options;

  mutable std::mutex mutex;
  int fd;
  int wake_read = -1;
  int wake_write = -1;
  Outbox outbox;
  bool ended = false;
  End end_reason = End::kClosed;
  // A write found the peer's end closed: nothing more is written, and the
  // reader reads what the peer sent until EOF, as Mojo's
  // ChannelPosix::OnWriteError keeps reading on kDisconnected.
  bool reject_writes = false;
  // ~Channel ran: posted drains deliver nothing.
  bool detached = false;
  std::optional<std::chrono::steady_clock::time_point> over_since;
  uint64_t quota_excess = 0;
  uint64_t coalesced = 0;
  // Read and not run on the UI thread yet; the drain task takes it whole.
  std::vector<Message> inbox;
  bool drain_posted = false;
  bool paused = false;       // inbox at its limit: the reader does not read
  bool reader_done = false;  // the reader closed its descriptors; on_end may run
  bool end_delivered = false;
  std::thread reader;

  // The reader thread (or a writer) may stop polling: one byte wakes it.
  void WakeLocked() {
    if (wake_write < 0) return;
    const uint8_t byte = 1;
    // A full pipe already holds a wake.
    (void)!::write(wake_write, &byte, 1);
  }

  bool Writable() const { return !ended && !reject_writes; }

  // Writes outbox entries while the socket takes them, one sendmsg per batch
  // (Outbox::Gather). False when nothing more can be written: the socket
  // failed (the channel ends), or the peer closed its end (the outbox is
  // dropped; the reader reads to EOF).
  bool FlushLocked() {
    iovec iov[kMaxBatch];
    for (;;) {
      const std::vector<int>* fds = nullptr;
      const size_t count = outbox.Gather(iov, kMaxBatch, &fds);
      if (count == 0) break;
      size_t offered = 0;
      for (size_t i = 0; i < count; ++i) offered += iov[i].iov_len;
      const ssize_t written = SendBatch(iov, count, fds);
      if (written < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EPIPE || errno == ECONNRESET) {
          reject_writes = true;
          outbox.Clear();
          over_since.reset();
          WakeLocked();
        } else {
          EndLocked(End::kIoError);
        }
        return false;
      }
      outbox.Advance(static_cast<size_t>(written));
      if (static_cast<size_t>(written) < offered) break;
    }
    if (!outbox.OverQuota()) over_since.reset();
    return true;
  }

  ssize_t SendBatch(iovec* iov, size_t count, const std::vector<int>* fds) {
    msghdr header;
    std::memset(&header, 0, sizeof header);
    header.msg_iov = iov;
    header.msg_iovlen = static_cast<decltype(header.msg_iovlen)>(count);
    alignas(cmsghdr) uint8_t control[CMSG_SPACE(sizeof(int) * kMaxFds)];
    if (fds != nullptr) {
      const size_t size = sizeof(int) * fds->size();
      std::memset(control, 0, sizeof control);
      header.msg_control = control;
      header.msg_controllen = CMSG_SPACE(size);
      cmsghdr* message = CMSG_FIRSTHDR(&header);
      message->cmsg_level = SOL_SOCKET;
      message->cmsg_type = SCM_RIGHTS;
      message->cmsg_len = CMSG_LEN(size);
      std::memcpy(CMSG_DATA(message), fds->data(), size);
    }
#if defined(MSG_NOSIGNAL)
    return ::sendmsg(fd, &header, MSG_NOSIGNAL);
#else
    return ::sendmsg(fd, &header, 0);
#endif
  }

  // Ends the channel once. The reader thread then stops and posts the end,
  // after every message it read before it.
  void EndLocked(End reason) {
    if (ended) return;
    ended = true;
    end_reason = reason;
    outbox.Clear();
    over_since.reset();
    if (fd >= 0) ::shutdown(fd, SHUT_RDWR);
    WakeLocked();
  }

  // The UI thread task: the batch read since the last one, then the end once
  // the reader has stopped; a reader paused at the inbox limit reads again.
  void Drain() {
    std::vector<Message> batch;
    bool deliver_end = false;
    End reason;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (detached) return;  // ~Core closes what the inbox holds
      batch.swap(inbox);
      drain_posted = false;
      if (paused) {
        paused = false;
        WakeLocked();
      }
      if (reader_done && !end_delivered) {
        end_delivered = true;
        deliver_end = true;
      }
      reason = end_reason;
    }
    if (!batch.empty()) on_messages(std::move(batch));
    if (deliver_end) on_end(reason);
  }

  // True when the caller must post a drain.
  bool NeedsDrainLocked() {
    if (drain_posted) return false;
    drain_posted = true;
    return true;
  }

  void PostDrain() {
    std::shared_ptr<Core> self = shared_from_this();
    post([self] { self->Drain(); });
  }

  // Reads what the socket holds; false when the connection must end
  // (`reason` says why).
  bool ReadAvailable(std::vector<uint8_t>* buffer, std::deque<int>* fds, End* reason) {
    uint8_t chunk[64 * 1024];
    // wakeup-allow: bounded reads only what the socket holds: ends at EAGAIN, EOF or an error
    for (;;) {
      iovec iov;
      iov.iov_base = chunk;
      iov.iov_len = sizeof chunk;
      alignas(cmsghdr) uint8_t control[CMSG_SPACE(sizeof(int) * 4 * kMaxFds)];
      msghdr header;
      std::memset(&header, 0, sizeof header);
      header.msg_iov = &iov;
      header.msg_iovlen = 1;
      header.msg_control = control;
      header.msg_controllen = sizeof control;
#if defined(MSG_CMSG_CLOEXEC)
      const ssize_t count = ::recvmsg(fd, &header, MSG_CMSG_CLOEXEC);
#else
      const ssize_t count = ::recvmsg(fd, &header, 0);
#endif
      if (count < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return true;
        // ECONNRESET: the peer closed with our frames unread.
        *reason = errno == ECONNRESET ? End::kPeerClosed : End::kIoError;
        return false;
      }
      for (cmsghdr* message = CMSG_FIRSTHDR(&header); message != nullptr; message = CMSG_NXTHDR(&header, message)) {
        if (message->cmsg_level != SOL_SOCKET || message->cmsg_type != SCM_RIGHTS) continue;
        const size_t received = (message->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < received; ++i) {
          int received_fd;
          std::memcpy(&received_fd, CMSG_DATA(message) + i * sizeof(int), sizeof(int));
          ::fcntl(received_fd, F_SETFD, FD_CLOEXEC);
          fds->push_back(received_fd);
        }
      }
      if ((header.msg_flags & MSG_CTRUNC) != 0) {
        *reason = End::kMalformed;  // more descriptors than any frame may carry
        return false;
      }
      if (count == 0) {
        *reason = End::kPeerClosed;
        return false;
      }
      buffer->insert(buffer->end(), chunk, chunk + count);
      size_t start = 0;
      bool post_drain = false;
      bool stop = false;
      // wakeup-allow: bounded each pass takes one whole frame of the bytes read, or stops
      for (;;) {
        Message message;
        size_t consumed = 0;
        const Parse parse = Decode(buffer->data() + start, buffer->size() - start, fds, &message, &consumed);
        if (parse == Parse::kNeedMore) break;
        if (parse == Parse::kMalformed) {
          for (int received_fd : message.fds) ::close(received_fd);
          *reason = End::kMalformed;
          if (post_drain) PostDrain();
          return false;
        }
        start += consumed;
        std::lock_guard<std::mutex> lock(mutex);
        inbox.push_back(std::move(message));
        post_drain = NeedsDrainLocked() || post_drain;
        if (inbox.size() >= options.inbox_limit) {
          paused = true;
          stop = true;
        }
      }
      // Descriptors that came with a frame declaring fewer, which no later frame may take.
      if (!PendingFdsFit(buffer->data() + start, buffer->size() - start, fds->size())) {
        *reason = End::kMalformed;
        if (post_drain) PostDrain();
        return false;
      }
      buffer->erase(buffer->begin(), buffer->begin() + static_cast<std::ptrdiff_t>(start));
      if (post_drain) PostDrain();
      if (stop) return true;
    }
  }

  void Run() {
#if defined(__APPLE__)
    pthread_setname_np("com.cmuxterm.chromium-host.control");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    std::vector<uint8_t> buffer;
    std::deque<int> fds;
    for (;;) {
      pollfd polls[2];
      int timeout = -1;
      bool want_read = false;
      bool want_write = false;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (ended) break;
        want_read = !paused;
        want_write = !outbox.empty();
        const short events = static_cast<short>((want_read ? POLLIN : 0) | (want_write ? POLLOUT : 0));
        // Paused with nothing to write: a hang-up must not spin the loop.
        polls[0].fd = events == 0 ? -1 : fd;
        polls[0].events = events;
        if (over_since) {
          const auto left = options.quota_ceiling - (std::chrono::steady_clock::now() - *over_since);
          timeout = static_cast<int>(
              std::max<int64_t>(0, std::chrono::ceil<std::chrono::milliseconds>(left).count()));
        }
      }
      polls[0].revents = 0;
      polls[1].fd = wake_read;
      polls[1].events = POLLIN;
      polls[1].revents = 0;
      // wakeup-allow: deadline the quota ceiling's one deadline while over quota; no timeout otherwise
      const int ready = ::poll(polls, 2, timeout);
      if (ready < 0 && errno != EINTR) {
        std::lock_guard<std::mutex> lock(mutex);
        EndLocked(End::kIoError);
        break;
      }
      if (ready > 0 && polls[1].revents != 0) {
        uint8_t drained[64];
        while (::read(wake_read, drained, sizeof drained) > 0) {
        }
      }
      const short got = polls[0].revents;
      if (want_write && (got & (POLLOUT | POLLERR | POLLHUP)) != 0) {
        // On a hang-up the write fails as EPIPE and the read below finds EOF.
        std::lock_guard<std::mutex> lock(mutex);
        if (Writable()) FlushLocked();
      }
      if (want_read && (got & (POLLIN | POLLERR | POLLHUP)) != 0) {
        End reason = End::kClosed;
        if (!ReadAvailable(&buffer, &fds, &reason)) {
          std::lock_guard<std::mutex> lock(mutex);
          EndLocked(reason);
          break;
        }
      }
      std::lock_guard<std::mutex> lock(mutex);
      if (over_since && std::chrono::steady_clock::now() - *over_since >= options.quota_ceiling) {
        if (outbox.OverQuota()) {
          EndLocked(End::kQuotaCeiling);
        } else {
          over_since.reset();
        }
      }
    }
    CloseAll(&fds);
    bool post_drain;
    {
      std::lock_guard<std::mutex> lock(mutex);
      ::close(fd);
      fd = -1;
      ::close(wake_read);
      ::close(wake_write);
      wake_read = wake_write = -1;
      reader_done = true;
      post_drain = NeedsDrainLocked();
    }
    if (post_drain) PostDrain();
  }
};

Channel::Channel(int fd, Post post, OnMessages on_messages, OnEnd on_end)
    : Channel(fd, std::move(post), std::move(on_messages), std::move(on_end), Options()) {}

Channel::Channel(int fd, Post post, OnMessages on_messages, OnEnd on_end, Options options)
    : core_(std::make_shared<Core>(fd, std::move(post), std::move(on_messages), std::move(on_end), options)) {
  ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
  ::fcntl(fd, F_SETFD, FD_CLOEXEC);
#if defined(SO_NOSIGPIPE)
  int one = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  int wake[2];
  if (::pipe(wake) == 0) {
    for (int end : wake) {
      ::fcntl(end, F_SETFL, ::fcntl(end, F_GETFL) | O_NONBLOCK);
      ::fcntl(end, F_SETFD, FD_CLOEXEC);
    }
    core_->wake_read = wake[0];
    core_->wake_write = wake[1];
  } else {
    core_->EndLocked(End::kIoError);  // no thread yet: nothing else holds the core
  }
  std::shared_ptr<Core> core = core_;
  core_->reader = std::thread([core] { core->Run(); });
}

Channel::~Channel() {
  {
    std::lock_guard<std::mutex> lock(core_->mutex);
    core_->detached = true;
    core_->EndLocked(End::kClosed);
  }
  if (core_->reader.joinable()) core_->reader.join();
}

bool Channel::Send(const Message& message, std::optional<uint64_t> state_key) {
  std::vector<uint8_t> bytes;
  if (!Encode(message, &bytes)) return false;
  Core& core = *core_;
  std::lock_guard<std::mutex> lock(core.mutex);
  if (!core.Writable()) return false;
  std::vector<int> fds;
  for (int fd : message.fds) {
    const int copy = ::fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (copy < 0) {
      for (int made : fds) ::close(made);
      return false;
    }
    fds.push_back(copy);
  }
  const bool was_empty = core.outbox.empty();
  if (core.outbox.Push(std::move(bytes), std::move(fds), state_key)) ++core.coalesced;
  if (was_empty) {
    if (!core.FlushLocked()) return false;
    if (!core.outbox.empty()) core.WakeLocked();  // the reader now watches for write
  }
  if (core.outbox.OverQuota()) {
    ++core.quota_excess;
    if (!core.over_since) {
      core.over_since = std::chrono::steady_clock::now();
      core.WakeLocked();  // the reader now keeps the ceiling's deadline
    }
  } else {
    core.over_since.reset();  // coalescing can bring it under quota while the socket takes nothing
  }
  return true;
}

void Channel::Close() {
  std::lock_guard<std::mutex> lock(core_->mutex);
  core_->EndLocked(End::kClosed);
}

Stats Channel::stats() const {
  std::lock_guard<std::mutex> lock(core_->mutex);
  Stats stats;
  stats.quota_excess = core_->quota_excess;
  stats.coalesced = core_->coalesced;
  stats.pending_messages = core_->outbox.messages();
  stats.pending_bytes = core_->outbox.bytes();
  return stats;
}

size_t Channel::PendingWithKey(uint64_t state_key) const {
  std::lock_guard<std::mutex> lock(core_->mutex);
  return core_->outbox.CountKey(state_key);
}

}  // namespace cmux_host::control
