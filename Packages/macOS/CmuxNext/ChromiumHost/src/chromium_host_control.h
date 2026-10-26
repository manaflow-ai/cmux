// The control channel between cmux and the Chromium host
// (plans/cmux-next/chrome-parity/p01-process.md 3.1, task p01-process-012).
// Input frames go on the shm ring (task 041); everything else goes here.
// CmuxNextBrowser mirrors it in ChromiumHostControlChannel.swift; the golden
// frame in ../tests/chromium_host_control_test.cpp and
// ChromiumHostControlChannelTests.swift is the same. Needs no CEF:
// scripts/cmux-next/tests/chromium-host-wire.test.sh compiles it alone.
//
// A frame, little-endian:
//   u32 len | u16 op | u16 flags | u32 token | len bytes of TLV fields
//   field:  u8 type | u8 tag | u16 length | length bytes
//   types:  1 i32 (4 bytes), 2 i64 (8), 3 f64 (8), 4 bytes, 5 str (UTF-8),
//           6 shared bytes, 7 shared str (8: the u64 byte count of a payload
//           in a shared memory descriptor; wire only, see below)
//   flags:  bits 0-2 the number of descriptors (SCM_RIGHTS) that came with
//           the frame's first byte, at most kMaxFds; bit 3 the frame answers
//           `token`; other bits are 0.
//
// Large payloads (task 020), as mojo_base::BigBuffer
// (mojo/public/cpp/base/big_buffer.h) moves bytes over its 64 KiB inline
// limit into a shared memory region: Channel::Send moves every bytes or str
// field over 65,535 bytes, then the largest ones until the body fits
// kMaxBody, into one sealed region each (CreateSharedRegion) and writes a
// shared field in its place. A frame's last descriptors are its shared
// fields' regions, in field order. The receiver maps each, copies it into
// the field, closes it and delivers an ordinary bytes or str field, so a
// socket frame is never over kHeaderSize + kMaxBody and callers never see
// a shared field. A region that is not sealed (Linux: no write, grow and
// shrink seals; elsewhere: not a read-only descriptor), is smaller than its
// count, or a count of 0 or over kMaxSharedBytes, is malformed. The seal
// (on macOS: xnu sizes a POSIX shm object once) keeps a region from
// shrinking under the receiver's mapping (a macOS shm descriptor has no read).
//
// Bounds, after Chrome's: a malformed frame (a length over kMaxBody, an
// unknown flag or type, a field past the body, bad UTF-8, a descriptor count
// that did not arrive) ends the connection, as
// bad_message::ReceivedBadMessage ends a renderer
// (content/browser/bad_message.cc). A peer that stops reading never blocks
// the writer: frames the socket refuses wait in the writer's outbox, as in
// Mojo's ChannelPosix (mojo/core/channel_posix.cc: write now when nothing
// waits, else queue and watch the descriptor for write). State ops coalesce
// there by (op, browser): a newer one replaces the waiting one. Past
// kQuotaBytes or kQuotaMessages the outbox is over quota: that is counted
// (quota_excess), as mojo/public/cpp/bindings/lib/message_quota_checker.cc
// only reports, and ends the connection only after kQuotaCeilingSeconds over
// quota without a break.
#pragma once

#include <sys/uio.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace cmux_host::control {

inline constexpr size_t kHeaderSize = 12;
inline constexpr size_t kFieldHeaderSize = 4;
// Larger payloads go as a sealed shm descriptor (task 020).
inline constexpr uint32_t kMaxBody = 64 * 1024;
inline constexpr size_t kMaxFds = 4;
// One shared field's most bytes: IPC::Channel::kMaximumMessageSize
// (ipc/ipc_channel.h), Chrome's largest IPC message.
inline constexpr uint64_t kMaxSharedBytes = 128 * 1024 * 1024;
inline constexpr size_t kQuotaBytes = 256 * 1024;
inline constexpr size_t kQuotaMessages = 4096;
inline constexpr int kQuotaCeilingSeconds = 60;
// Messages read and not yet run on the UI thread: past it the reader stops
// reading until the UI thread drains (the peer's outbox then holds them).
inline constexpr size_t kInboxLimit = 4096;
// Waiting frames one sendmsg writes (Outbox::Gather).
inline constexpr size_t kMaxBatch = 64;

inline constexpr uint16_t kFdCountMask = 0x0007;
inline constexpr uint16_t kFlagReply = 0x0008;
inline constexpr uint16_t kKnownFlags = kFdCountMask | kFlagReply;

enum class Type : uint8_t { kI32 = 1, kI64 = 2, kF64 = 3, kBytes = 4, kStr = 5 };

struct Field {
  uint8_t tag = 0;
  Type type = Type::kI32;
  int64_t integer = 0;  // kI32, kI64
  double real = 0;      // kF64
  std::string bytes;    // kBytes, kStr

  static Field I32(uint8_t tag, int32_t value);
  static Field I64(uint8_t tag, int64_t value);
  static Field F64(uint8_t tag, double value);
  static Field Bytes(uint8_t tag, std::string value);
  static Field Str(uint8_t tag, std::string value);
  bool operator==(const Field& other) const;
};

struct Message {
  uint16_t op = 0;
  bool reply = false;  // answers `token`
  uint32_t token = 0;
  std::vector<Field> fields;
  // Sent: the sender's descriptors (the channel sends duplicates). Received:
  // descriptors the receiver owns and closes.
  std::vector<int> fds;

  const Field* Find(uint8_t tag) const;
};

// The frame of `message` appended to `out`; false (nothing appended) when it
// would break a bound: a body over kMaxBody, a field over 65,535 bytes, more
// than kMaxFds descriptors, invalid UTF-8 in a str field.
bool Encode(const Message& message, std::vector<uint8_t>* out);

// The bytes and str fields of `message` that go in shared memory so its frame
// fits (indices, ascending): every one over 65,535 bytes, then the largest
// until the body is at most kMaxBody. Empty when it fits as it is.
std::vector<size_t> SharedFields(const Message& message);

// Encode with the fields at `shared` (from SharedFields) written as shared
// fields; the frame declares message.fds plus one descriptor per shared field.
bool EncodeShared(const Message& message, const std::vector<size_t>& shared, std::vector<uint8_t>* out);

// A sealed region holding `data` (Linux: a memfd with its write, grow, shrink
// and seal seals; elsewhere: a read-only descriptor of a shm_open object
// unlinked at once, its writable one closed; macOS sizes a POSIX shm object
// once, so it never shrinks under a reader), close-on-exec, or -1.
int CreateSharedRegion(const std::string& data);

enum class Parse { kFrame, kNeedMore, kMalformed };

// Decodes the first frame of `data`. `fds` holds the descriptors received and
// not given to a frame yet, oldest first; a frame takes its count from the
// front. kMalformed as soon as the header is bad, before its body arrives.
// Shared fields are read here: their regions are copied into the fields and
// closed, and `out->fds` holds only the frame's other descriptors.
Parse Decode(const uint8_t* data, size_t size, std::deque<int>* fds, Message* out, size_t* consumed);

bool IsValidUtf8(const std::string& text);

// Whether `pending` descriptors, received and not taken by a whole frame, can
// belong to the frame `data` starts. They travel with a frame's first byte, so
// they must come with a started frame and be no more than its header
// declares; extra ones are malformed (Mojo rejects a message whose handle
// count does not match what came with it).
bool PendingFdsFit(const uint8_t* data, size_t size, size_t pending);

// The key a state op coalesces by.
inline uint64_t StateKey(uint16_t op, int32_t browser) {
  return (static_cast<uint64_t>(op) << 32) | static_cast<uint32_t>(browser);
}

// Frames the socket has not taken yet, oldest first. A partly written front
// frame keeps its place (it is in flight, not waiting); a waiting state op is
// replaced by a newer one with the same key, which goes to the tail. Writes go
// in batches, one sendmsg each, as ChannelPosix::WriteOutgoingMessagesWithWritev
// batches messages without handles: a frame with descriptors starts a batch,
// since they go with its first byte. Owns the duplicated descriptors.
class Outbox {
 public:
  struct Entry {
    std::vector<uint8_t> bytes;
    std::vector<int> fds;
    size_t offset = 0;  // bytes already written; fds go with byte 0
    std::optional<uint64_t> key;
    bool live = true;  // false: replaced by a newer state op
    // Payload bytes in shared regions among `fds`: they count toward the
    // quota, so a peer that stops reading reaches the ceiling as with
    // inline bytes.
    size_t shared_bytes = 0;
  };

  Outbox(size_t quota_bytes, size_t quota_messages);
  ~Outbox();
  Outbox(const Outbox&) = delete;
  Outbox& operator=(const Outbox&) = delete;

  // True when it replaced a waiting entry with the same key (a partly
  // written one is never replaced).
  bool Push(std::vector<uint8_t> bytes, std::vector<int> fds, std::optional<uint64_t> key, size_t shared_bytes = 0);
  // The oldest live entry, nullptr when empty.
  Entry* Front();
  // The next batch, at most `max` buffers: the front entry's unwritten bytes,
  // then whole entries up to the next one with descriptors. `fds`: the front
  // entry's descriptors when the batch starts at its first byte, else nullptr.
  size_t Gather(iovec* iov, size_t max, const std::vector<int>** fds);
  // Marks `written` bytes from the front sent: whole entries leave, and a
  // started entry's descriptors close (they went with its first byte).
  void Advance(size_t written);
  // Drops the front entry (written whole), closing its descriptors.
  void PopFront();
  void Clear();

  bool empty() const { return messages_ == 0; }
  size_t messages() const { return messages_; }
  size_t bytes() const { return bytes_; }
  bool OverQuota() const { return bytes_ > quota_bytes_ || messages_ > quota_messages_; }
  // Waiting entries with this key (0 or 1): live and not started.
  size_t CountKey(uint64_t key) const;
  // Closes an entry's descriptors (once sent, or when it is dropped).
  static void CloseFds(Entry* entry);

 private:
  void Drop(Entry* entry);
  void Compact();

  const size_t quota_bytes_;
  const size_t quota_messages_;
  std::deque<Entry> entries_;
  // The live entry of each state key: its index in entries_ plus removed_.
  std::unordered_map<uint64_t, uint64_t> keyed_;
  uint64_t removed_ = 0;  // entries popped from the front since the last Compact
  size_t dead_ = 0;       // replaced entries still in entries_
  size_t messages_ = 0;
  size_t bytes_ = 0;
};

enum class End {
  kClosed,        // Close()
  kPeerClosed,    // EOF
  kMalformed,     // a bad frame
  kQuotaCeiling,  // over quota for the whole ceiling
  kIoError,       // the socket failed
};

struct Stats {
  uint64_t quota_excess = 0;  // sends while the outbox was over quota
  uint64_t coalesced = 0;     // waiting state ops replaced by a newer one
  size_t pending_messages = 0;
  size_t pending_bytes = 0;
};

// One end of the control socket. Send from any thread never blocks; the
// reader thread com.cmuxterm.chromium-host.control reads, writes what the
// outbox holds once the socket takes it, and posts each batch of messages to
// the UI thread with one task (`post`, CefPostTask(TID_UI) in the host).
class Channel {
 public:
  using Post = std::function<void(std::function<void()>)>;
  using OnMessages = std::function<void(std::vector<Message>)>;
  using OnEnd = std::function<void(End)>;
  struct Options {
    size_t quota_bytes = kQuotaBytes;
    size_t quota_messages = kQuotaMessages;
    std::chrono::milliseconds quota_ceiling = std::chrono::seconds(kQuotaCeilingSeconds);
    size_t inbox_limit = kInboxLimit;
  };

  // Takes `fd` (a connected stream socket). `post` runs a task on the UI
  // thread; `on_messages` and then, once, `on_end` run in such tasks.
  Channel(int fd, Post post, OnMessages on_messages, OnEnd on_end, Options options);
  Channel(int fd, Post post, OnMessages on_messages, OnEnd on_end);
  // Ends the channel and joins the reader. Nothing is delivered after it: a
  // task already posted runs neither callback, as a task bound to a WeakPtr
  // (base/memory/weak_ptr.h) does not run once its owner is gone. Destroy it on
  // the UI thread, where those tasks run.
  ~Channel();
  Channel(const Channel&) = delete;
  Channel& operator=(const Channel&) = delete;

  // Queues `message` (its descriptors duplicated) and writes it when the
  // socket takes it; fields too large for a frame go in shared memory
  // (SharedFields), created on the calling thread. `state_key`: a waiting
  // message with the same key is replaced. False when the channel has ended
  // or the message breaks a bound (then nothing is sent).
  bool Send(const Message& message, std::optional<uint64_t> state_key = std::nullopt);
  void Close();
  Stats stats() const;
  // Waiting messages with this state key (0 or 1); one the socket has taken
  // part of is in flight, not waiting.
  size_t PendingWithKey(uint64_t state_key) const;

 private:
  struct Core;
  std::shared_ptr<Core> core_;
};

}  // namespace cmux_host::control
