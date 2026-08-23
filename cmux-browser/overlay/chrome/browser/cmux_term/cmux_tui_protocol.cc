// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "chrome/browser/cmux_term/cmux_tui_protocol.h"

#include <algorithm>
#include <array>
#include <limits>
#include <utility>

#include <cstdio>

namespace cmux {

CmuxTuiRegistryFenceDecision FenceCmuxTuiRegistrySnapshot(
    bool has_current,
    std::string_view current_registry_id,
    std::string_view current_generation,
    uint64_t current_revision,
    std::string_view incoming_registry_id,
    std::string_view incoming_generation,
    uint64_t incoming_revision) {
  if (incoming_registry_id.empty() || incoming_generation.empty()) {
    return CmuxTuiRegistryFenceDecision::kInvalid;
  }
  if (!has_current || current_registry_id != incoming_registry_id ||
      current_generation != incoming_generation) {
    return CmuxTuiRegistryFenceDecision::kAccept;
  }
  if (incoming_revision < current_revision) {
    return CmuxTuiRegistryFenceDecision::kRefetch;
  }
  if (incoming_revision == current_revision) {
    return CmuxTuiRegistryFenceDecision::kIgnore;
  }
  return CmuxTuiRegistryFenceDecision::kAccept;
}

bool ValidateCmuxTuiTerminalEventRevisions(
    uint64_t after_revision,
    uint64_t batch_revision,
    const std::vector<uint64_t>& event_revisions) {
  if (batch_revision < after_revision) {
    return false;
  }
  uint64_t expected = after_revision;
  for (const uint64_t revision : event_revisions) {
    if (expected == std::numeric_limits<uint64_t>::max() ||
        revision != expected + 1) {
      return false;
    }
    expected = revision;
  }
  return expected == batch_revision;
}

bool IsCmuxTuiTreeEventName(std::string_view event_name) {
  constexpr std::array<std::string_view, 13> kTreeEvents = {
      "tree-changed",      "workspace-added", "workspace-closed",
      "workspace-renamed", "workspace-moved", "screen-added",
      "screen-closed",     "screen-renamed",  "pane-added",
      "pane-closed",       "tab-added",       "tab-closed",
      "tab-renamed",
  };
  return std::find(kTreeEvents.begin(), kTreeEvents.end(), event_name) !=
         kTreeEvents.end();
}

CmuxTuiIdentityError ValidateCmuxTuiIdentity(
    std::string_view app,
    uint64_t protocol,
    uint64_t pid,
    std::optional<std::string_view> build_commit,
    std::string_view required_build_commit,
    std::optional<std::string_view> ghostty_commit,
    std::string_view required_ghostty_commit) {
  if (app != "cmux-tui" || protocol < kMinCmuxTuiProtocolVersion ||
      protocol > kCmuxTuiProtocolVersion || pid == 0) {
    return CmuxTuiIdentityError::kInvalidEndpoint;
  }
  if (!required_build_commit.empty()) {
    if (!build_commit || build_commit->empty()) {
      return CmuxTuiIdentityError::kBuildCommitMissing;
    }
    if (*build_commit != required_build_commit) {
      return CmuxTuiIdentityError::kBuildCommitMismatch;
    }
  }
  // A recognizable older daemon must reach the stamped-build checks above so
  // the browser can replace it safely. It must never become ready, even in an
  // unpinned source-tree build.
  if (protocol != kCmuxTuiProtocolVersion) {
    return CmuxTuiIdentityError::kInvalidEndpoint;
  }
  if (required_ghostty_commit.empty()) {
    return CmuxTuiIdentityError::kNone;
  }
  if (!ghostty_commit || ghostty_commit->empty()) {
    return CmuxTuiIdentityError::kGhosttyCommitMissing;
  }
  if (*ghostty_commit != required_ghostty_commit) {
    return CmuxTuiIdentityError::kGhosttyCommitMismatch;
  }
  return CmuxTuiIdentityError::kNone;
}

bool IsReplaceableCmuxTuiIdentityError(CmuxTuiIdentityError error) {
  switch (error) {
    case CmuxTuiIdentityError::kBuildCommitMissing:
    case CmuxTuiIdentityError::kBuildCommitMismatch:
    case CmuxTuiIdentityError::kGhosttyCommitMissing:
    case CmuxTuiIdentityError::kGhosttyCommitMismatch:
      return true;
    case CmuxTuiIdentityError::kNone:
    case CmuxTuiIdentityError::kInvalidEndpoint:
      return false;
  }
  // Fail closed for an unrecognized value. Besides keeping GCC's control-flow
  // analysis honest, this prevents a future protocol error from silently
  // becoming permission to replace a process until it is classified above.
  return false;
}

std::string SelectCmuxTuiSocketPath(std::string_view preferred,
                                    std::string_view fallback,
                                    size_t native_path_capacity) {
  return preferred.size() < native_path_capacity ? std::string(preferred)
                                                  : std::string(fallback);
}

std::string CmuxTuiSha256Hex(std::string_view input) {
  // FIPS 180-4 SHA-256, implemented locally to avoid adding a browser crypto
  // dependency for this non-security namespace derivation.
  constexpr uint32_t k[64] = {
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
  uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  std::string bytes(input);
  const uint64_t bits = static_cast<uint64_t>(bytes.size()) * 8;
  bytes.push_back('\x80');
  while ((bytes.size() % 64) != 56) bytes.push_back('\0');
  for (int i = 7; i >= 0; --i) bytes.push_back(static_cast<char>(bits >> (i * 8)));
  auto rotr = [](uint32_t x, int n) { return (x >> n) | (x << (32 - n)); };
  for (size_t off = 0; off < bytes.size(); off += 64) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) w[i] = (static_cast<uint32_t>(static_cast<unsigned char>(bytes[off+4*i]))<<24)|(static_cast<uint32_t>(static_cast<unsigned char>(bytes[off+4*i+1]))<<16)|(static_cast<uint32_t>(static_cast<unsigned char>(bytes[off+4*i+2]))<<8)|static_cast<unsigned char>(bytes[off+4*i+3]);
    for (int i = 16; i < 64; ++i) { uint32_t s0=rotr(w[i-15],7)^rotr(w[i-15],18)^(w[i-15]>>3), s1=rotr(w[i-2],17)^rotr(w[i-2],19)^(w[i-2]>>10); w[i]=w[i-16]+s0+w[i-7]+s1; }
    uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],x=h[7];
    for (int i=0;i<64;++i) { uint32_t S1=rotr(e,6)^rotr(e,11)^rotr(e,25), ch=(e&f)^((~e)&g), t1=x+S1+ch+k[i]+w[i], S0=rotr(a,2)^rotr(a,13)^rotr(a,22), maj=(a&b)^(a&c)^(b&c), t2=S0+maj; x=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2; }
    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=x;
  }
  char out[65];
  for (int i=0;i<8;++i) std::snprintf(out+i*8,9,"%08x",h[i]);
  out[64]='\0';
  return out;
}

std::string CmuxTuiSocketFallbackPath(std::string_view session, uint32_t uid) {
  return "/tmp/cmux-tui-" + std::to_string(uid) + "/" + CmuxTuiSha256Hex(session) + ".sock";
}

std::vector<uint8_t> StripCmuxTuiReplayPalette(std::string_view replay) {
  std::vector<uint8_t> filtered;
  filtered.reserve(replay.size());
  size_t cursor = 0;
  while (cursor < replay.size()) {
    const bool seven_bit_osc4 =
        cursor + 3 < replay.size() && replay[cursor] == '\x1b' &&
        replay[cursor + 1] == ']' && replay[cursor + 2] == '4' &&
        replay[cursor + 3] == ';';
    const bool eight_bit_osc4 = cursor + 2 < replay.size() &&
                                static_cast<uint8_t>(replay[cursor]) == 0x9d &&
                                replay[cursor + 1] == '4' &&
                                replay[cursor + 2] == ';';
    if (!seven_bit_osc4 && !eight_bit_osc4) {
      filtered.push_back(static_cast<uint8_t>(replay[cursor++]));
      continue;
    }

    size_t end = cursor + (seven_bit_osc4 ? 4 : 3);
    bool terminated = false;
    while (end < replay.size()) {
      const uint8_t byte = static_cast<uint8_t>(replay[end]);
      if (byte == 0x07 || byte == 0x9c) {
        ++end;
        terminated = true;
        break;
      }
      if (byte == 0x1b && end + 1 < replay.size() && replay[end + 1] == '\\') {
        end += 2;
        terminated = true;
        break;
      }
      ++end;
    }
    if (!terminated) {
      filtered.insert(filtered.end(), replay.begin() + cursor, replay.end());
      break;
    }
    cursor = end;
  }
  return filtered;
}

CmuxTuiInputQueue::CmuxTuiInputQueue(size_t max_pending_bytes)
    : max_pending_bytes_(max_pending_bytes) {}

CmuxTuiInputQueue::~CmuxTuiInputQueue() = default;

bool CmuxTuiInputQueue::Push(std::string_view bytes) {
  if (bytes.empty()) {
    return true;
  }
  if (pending_.size() > max_pending_bytes_ ||
      bytes.size() > max_pending_bytes_ - pending_.size()) {
    return false;
  }
  pending_.insert(pending_.end(), bytes.begin(), bytes.end());
  return true;
}

std::vector<uint8_t> CmuxTuiInputQueue::BeginWrite() {
  if (write_in_flight_ || pending_.empty()) {
    return {};
  }
  write_in_flight_ = true;
  std::vector<uint8_t> result;
  result.swap(pending_);
  return result;
}

void CmuxTuiInputQueue::FinishWrite() {
  write_in_flight_ = false;
}

void CmuxTuiInputQueue::CancelWrite() {
  write_in_flight_ = false;
}

void CmuxTuiInputQueue::Clear() {
  pending_.clear();
  write_in_flight_ = false;
}

void CmuxTuiResizeCoalescer::SetDesired(uint16_t cols, uint16_t rows) {
  desired_ = {std::max<uint16_t>(cols, 1), std::max<uint16_t>(rows, 1)};
}

std::optional<CmuxTuiGridSize> CmuxTuiResizeCoalescer::BeginWrite(
    CmuxTuiGridSize current) {
  if (write_in_flight_ || desired_ == current) {
    return std::nullopt;
  }
  write_in_flight_ = true;
  return desired_;
}

void CmuxTuiResizeCoalescer::FinishWrite() {
  write_in_flight_ = false;
}

void CmuxTuiResizeCoalescer::CancelWrite() {
  write_in_flight_ = false;
}

CmuxTuiLineFramer::CmuxTuiLineFramer(size_t max_line_bytes)
    : max_line_bytes_(max_line_bytes) {}

CmuxTuiLineFramer::~CmuxTuiLineFramer() = default;

CmuxTuiLineFramer::Result CmuxTuiLineFramer::Push(
    std::string_view bytes,
    std::vector<std::string>* lines) {
  if (!lines) {
    Reset();
    return Result::kLineTooLarge;
  }

  while (!bytes.empty()) {
    const size_t newline = bytes.find('\n');
    const std::string_view piece =
        newline == std::string_view::npos ? bytes : bytes.substr(0, newline);
    if (piece.size() > max_line_bytes_ - pending_.size()) {
      Reset();
      return Result::kLineTooLarge;
    }
    pending_.append(piece);

    if (newline == std::string_view::npos) {
      return Result::kOk;
    }

    if (!pending_.empty() && pending_.back() == '\r') {
      pending_.pop_back();
    }
    if (!pending_.empty()) {
      lines->push_back(std::move(pending_));
      pending_.clear();
    }
    bytes.remove_prefix(newline + 1);
  }

  return Result::kOk;
}

void CmuxTuiLineFramer::Reset() {
  pending_.clear();
}

}  // namespace cmux
