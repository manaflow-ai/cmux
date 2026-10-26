// The remote shim's mirror cache (libcmux_cef_shim_remote.dylib,
// plans/cmux-next/chrome-parity/p01-process.md, task 016b): the values of the
// `mirror` class exports (plans/cmux-next/chromium-host-ops.json), served to
// cmux on its main thread with no lock and no wait for the host. Chrome's
// browser process answers NSTextInputClient queries the same way, from the
// TextInputState the renderer pushed (content/browser/renderer_host/
// text_input_manager.cc), never with a sync call to the renderer.
//
// The host pushes a MIRROR frame before the EVENT that refreshes it (task
// 013). ApplyBatch runs on main over one per-frame batch in arrival order, so
// each event's handler reads the values pushed for it and none pushed after.
//
// Read your writes: a post that changes mirror keys (`pending_keys`) calls
// MarkPending under its token before it is sent. Until the host's ACK for that
// token, a read of a matching key returns the optimistic value when the post
// gave one, else the pending marker (Read::value == nullptr, which the
// generated export returns as its C zero value), never the value from before
// the post. The host sends the ACK after the pushes its dispatch of the op
// made (HostContext holds replies while it dispatches), so the value read
// after the ACK is the host's. A post the transport did not send has no ACK
// coming: the transport calls DropPending.
//
// Main thread only, asserted, as the in-process shim (cmux_cef_shim.h,
// "Threading"): no lock on any path. Plain C++ (no Objective-C), so
// tests/remote_shim_mirror_test.cpp runs it anywhere
// (scripts/cmux-next/tests/remote-shim-mirror.test.sh). Its Swift twin is
// ChromiumHostMirror.swift; both follow the same rules.
#pragma once

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <unordered_map>
#include <iterator>
#include <utility>
#include <vector>

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

#include "chromium_host_control.h"

namespace cmux_remote {

class MirrorCache {
 public:
  using Field = cmux_host::control::Field;
  using Fields = std::vector<Field>;
  using Message = cmux_host::control::Message;

  // The generator's kOpMirror and kOpAck (gen-chromium-host-wire.py
  // MIRROR_OP, ACK_OP; remote-shim-mirror.test.sh checks they agree).
  static constexpr uint16_t kMirrorOp = 0x8003;
  static constexpr uint16_t kAckOp = 0x8004;
  // Op ids of exports are 1..N; host -> cmux ops start at 0x8000.
  static constexpr int32_t kMaxExportOp = 0x7fff;

  enum class State { kAbsent, kPending, kValue };
  // `value` points into the cache until the next call that changes it; it is
  // null for kAbsent and for the pending marker, and holds the optimistic
  // value for a pending key whose post gave one.
  struct Read {
    State state = State::kAbsent;
    const Fields* value = nullptr;
  };

  enum class Applied {
    kNotMirror,  // an EVENT or anything else: the caller handles it
    kApplied,
    kMalformed,  // the connection ends (p01-process section 4, rule 2)
  };

  MirrorCache() = default;
  MirrorCache(const MirrorCache&) = delete;
  MirrorCache& operator=(const MirrorCache&) = delete;

  // Marks the keys of `mirror_op` that `key` matches as pending under
  // `token` (non-zero). `key` holds the key's parameters in order, without
  // those whose bit is set in `wildcards` (bit i: parameter i is `*`).
  void MarkPending(uint16_t mirror_op, uint32_t token, const Fields& key, uint32_t wildcards,
                   std::optional<Fields> optimistic = std::nullopt) {
    AssertMainThread();
    if (token == 0) return;  // no ACK would clear it
    pending_[mirror_op].push_back(Pending{token, key, wildcards, std::move(optimistic)});
  }

  // The post under `token` was not sent: no ACK comes for it.
  void DropPending(uint32_t token) {
    AssertMainThread();
    ClearToken(token);
  }

  // The value of `mirror_op` for `key` (every parameter, in order). The
  // newest pending post that matches decides while it waits for its ACK.
  Read Lookup(uint16_t mirror_op, const Fields& key) const {
    AssertMainThread();
    if (auto waiting = pending_.find(mirror_op); waiting != pending_.end()) {
      for (auto it = waiting->second.rbegin(); it != waiting->second.rend(); ++it) {
        if (!Matches(*it, key)) continue;
        return Read{State::kPending, it->optimistic ? &*it->optimistic : nullptr};
      }
    }
    auto values = values_.find(mirror_op);
    if (values == values_.end()) return Read{};
    auto entry = values->second.find(KeyBytes(key.begin(), key.end()));
    if (entry == values->second.end()) return Read{};
    return Read{State::kValue, &entry->second};
  }

  // One message of a batch. A MIRROR frame is
  //   i32 mirror op | i32 key field count | key fields | value fields
  // (HostContext::PushMirror); an ACK is a reply frame with the op's token.
  Applied Apply(const Message& message) {
    AssertMainThread();
    if (message.op == kAckOp) {
      if (!message.reply || message.token == 0 || !message.fields.empty() || !message.fds.empty()) {
        return Applied::kMalformed;
      }
      ClearToken(message.token);
      return Applied::kApplied;
    }
    if (message.op != kMirrorOp) return Applied::kNotMirror;
    const Fields& f = message.fields;
    if (message.reply || !message.fds.empty() || f.size() < 2 || !IsI32(f[0]) || !IsI32(f[1])) {
      return Applied::kMalformed;
    }
    const int64_t op = f[0].integer;
    const int64_t key_count = f[1].integer;
    if (op < 1 || op > kMaxExportOp || key_count < 0 || key_count > static_cast<int64_t>(f.size() - 2)) {
      return Applied::kMalformed;
    }
    const auto key_end = f.begin() + 2 + key_count;
    values_[static_cast<uint16_t>(op)][KeyBytes(f.begin() + 2, key_end)] = Fields(key_end, f.end());
    return Applied::kApplied;
  }

  // Applies one per-frame batch in arrival order: each MIRROR or ACK before
  // the messages after it, and every other message to `other` as it comes.
  // False at a malformed one (the rest is not applied; the connection ends).
  template <typename Other>
  bool ApplyBatch(const std::vector<Message>& batch, Other&& other) {
    AssertMainThread();
    for (const Message& message : batch) {
      switch (Apply(message)) {
        case Applied::kApplied:
          break;
        case Applied::kNotMirror:
          other(message);
          break;
        case Applied::kMalformed:
          return false;
      }
    }
    return true;
  }

  // The host is gone: its values and every pending mark go with it (the next
  // host pushes its own at attach).
  void Clear() {
    AssertMainThread();
    values_.clear();
    pending_.clear();
  }

  size_t pending_count() const {
    AssertMainThread();
    size_t count = 0;
    for (const auto& entry : pending_) count += entry.second.size();
    return count;
  }

 private:
  struct Pending {
    uint32_t token;
    Fields key;  // the parameters not in `wildcards`, in order
    uint32_t wildcards;
    std::optional<Fields> optimistic;
  };

  // Like Chrome's DCHECK_CALLED_ON_VALID_SEQUENCE: the cache has no lock
  // because only the main thread touches it. Linux has the check too, so the
  // test there refuses a call from another thread.
  static void AssertMainThread() {
#if defined(__APPLE__)
    assert(pthread_main_np() != 0);
#elif defined(__linux__)
    assert(syscall(SYS_gettid) == getpid());
#endif
  }

  static bool IsI32(const Field& field) {
    return field.type == cmux_host::control::Type::kI32 && field.tag == 0;
  }

  static bool Matches(const Pending& pending, const Fields& key) {
    size_t named = 0;
    for (size_t i = 0; i < key.size(); ++i) {
      if (i < 32 && (pending.wildcards >> i) & 1u) continue;
      if (named >= pending.key.size() || !(pending.key[named] == key[i])) return false;
      ++named;
    }
    return named == pending.key.size();
  }

  // A key's fields as one hashable string: type, tag, then the value.
  template <typename It>
  static std::string KeyBytes(It begin, It end) {
    std::string bytes;
    for (It it = begin; it != end; ++it) {
      bytes.push_back(static_cast<char>(it->type));
      bytes.push_back(static_cast<char>(it->tag));
      switch (it->type) {
        case cmux_host::control::Type::kI32:
        case cmux_host::control::Type::kI64:
          AppendRaw(bytes, it->integer);
          break;
        case cmux_host::control::Type::kF64:
          AppendRaw(bytes, it->real);
          break;
        case cmux_host::control::Type::kBytes:
        case cmux_host::control::Type::kStr:
          AppendRaw(bytes, static_cast<uint64_t>(it->bytes.size()));
          bytes += it->bytes;
          break;
      }
    }
    return bytes;
  }

  template <typename T>
  static void AppendRaw(std::string& out, T value) {
    char raw[sizeof(T)];
    std::memcpy(raw, &value, sizeof(T));
    out.append(raw, sizeof(T));
  }

  void ClearToken(uint32_t token) {
    for (auto it = pending_.begin(); it != pending_.end();) {
      auto& list = it->second;
      list.erase(std::remove_if(list.begin(), list.end(), [token](const Pending& p) { return p.token == token; }),
                 list.end());
      it = list.empty() ? pending_.erase(it) : std::next(it);
    }
  }

  // mirror op -> key bytes -> the value fields the host pushed last.
  std::unordered_map<uint16_t, std::unordered_map<std::string, Fields>> values_;
  // mirror op -> pending marks, oldest first.
  std::unordered_map<uint16_t, std::vector<Pending>> pending_;
};

}  // namespace cmux_remote
