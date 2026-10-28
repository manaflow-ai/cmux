// The remote shim's mirror cache: the host's last value of each `mirror` export
// (plans/cmux-next/chromium-host-ops.json: tab_navigation_state, window_count,
// fork_api_version, ...), so a read returns in the caller's turn instead of asking another
// process. Chrome answers NSTextInputClient queries the same way, from the TextInputState
// the renderer pushed (content/browser/renderer_host/text_input_manager.cc).
//
// The host pushes a value (MIRROR) before the EVENT that changed it, and remote_shim.mm
// applies both in one main-thread batch, so code that reacts to the event reads the new
// value. A post with pending_keys marks those keys pending under its token until the host
// acks the token (an async op's REPLY acks it too): a read of a pending key finds no value,
// never the one the post changed.
//
// Main thread only, like every shim call (remote_shim.mm asserts it): no lock.
#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_remote {

class MirrorCache {
 public:
  using Field = cmux_host::control::Field;
  using TlvReader = cmux_host::control::TlvReader;

  // `key` is the export's arguments (out-parameters excluded); `value` the fields the host
  // pushed. An absent value forgets the key.
  void Set(uint16_t op, const std::vector<Field>& key, std::vector<Field> value) {
    values_.insert_or_assign(Key(op, key), std::move(value));
  }
  void Erase(uint16_t op, const std::vector<Field>& key) { values_.erase(Key(op, key)); }

  // The cached value; not present() when the host pushed none or a post made it pending.
  TlvReader Lookup(uint16_t op, const std::vector<Field>& key) const {
    if (IsPending(op, key)) return TlvReader();
    const auto it = values_.find(Key(op, key));
    return it == values_.end() ? TlvReader() : TlvReader(it->second);
  }

  // Bit i of `wildcards`: key parameter i is `*` (every value) and is absent from `key`.
  void MarkPending(uint16_t op, uint32_t token, const std::vector<Field>& key, uint32_t wildcards) {
    pending_.push_back(Pending{op, token, wildcards, Encoded(key)});
  }
  // The host ran the op of `token` (its ACK, or its REPLY).
  void Ack(uint32_t token) {
    std::erase_if(pending_, [token](const Pending& p) { return p.token == token; });
  }

  void Clear() {
    values_.clear();
    pending_.clear();
  }
  size_t size() const { return values_.size(); }
  size_t pending() const { return pending_.size(); }

 private:
  struct Pending {
    uint16_t op;
    uint32_t token;
    uint32_t wildcards;
    std::string key;  // the parameters wildcards does not cover, Encoded
  };

  static std::string Encoded(const std::vector<Field>& fields) {
    std::string out;
    cmux_host::control::EncodeFields(fields, &out);
    return out;
  }
  static std::string Key(uint16_t op, const std::vector<Field>& key) {
    std::string out;
    out.push_back(static_cast<char>(op & 0xff));
    out.push_back(static_cast<char>(op >> 8));
    cmux_host::control::EncodeFields(key, &out);
    return out;
  }
  bool IsPending(uint16_t op, const std::vector<Field>& key) const {
    for (const Pending& p : pending_) {
      if (p.op != op) continue;
      if (p.wildcards == 0) {
        if (p.key == Encoded(key)) return true;
        continue;
      }
      std::vector<Field> named;
      for (size_t i = 0; i < key.size(); ++i) {
        if (i >= 32 || (p.wildcards & (1u << i)) == 0) named.push_back(key[i]);
      }
      if (p.key == Encoded(named)) return true;
    }
    return false;
  }

  std::unordered_map<std::string, std::vector<Field>> values_;
  // Few at a time: each lives from its post to the host's ack.
  std::vector<Pending> pending_;
};

}  // namespace cmux_remote
