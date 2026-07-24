// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef CHROME_SERVICES_CMUX_TERMINAL_RENDERER_PUBLIC_CPP_CMUX_TERMINAL_HOST_PROTOCOL_H_
#define CHROME_SERVICES_CMUX_TERMINAL_RENDERER_PUBLIC_CPP_CMUX_TERMINAL_HOST_PROTOCOL_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace cmux {

inline constexpr std::array<uint8_t, 4> kTerminalHostMagic = {'C', 'M', 'T',
                                                              'H'};
inline constexpr size_t kTerminalHostHeaderLength = 32;
inline constexpr uint16_t kTerminalHostProtocolVersion = 2;
inline constexpr uint32_t kTerminalHostFlagColorsFollow = 1u << 0;
inline constexpr uint32_t kTerminalHostFlagViewerSizeAcks = 1u << 1;
inline constexpr uint32_t kTerminalHostResizeAckCanonicalChanged = 1u << 0;
inline constexpr size_t kTerminalHostMaxFramePayload = 16 * 1024 * 1024;
inline constexpr size_t kTerminalHostMaxSnapshotReplay = 15'692'630;
inline constexpr size_t kTerminalHostMaxKittyImageAliases = 4'096;
inline constexpr size_t kTerminalHostMaxString = 256 * 1024;
inline constexpr size_t kTerminalHostMaxCommandArguments = 256;
inline constexpr uint16_t kTerminalHostColorsVersionV1 = 1;
inline constexpr uint16_t kTerminalHostColorsVersion = 2;
inline constexpr size_t kTerminalHostPaletteSize = 256;
inline constexpr size_t kTerminalHostMaxColorsPayload =
    8 + 3 * 3 + 2 + kTerminalHostPaletteSize * 4;

enum class TerminalHostMessageKind : uint16_t {
  kBootstrap = 1,
  kReady = 2,
  kClientHello = 3,
  kHostHello = 4,
  kSnapshot = 5,
  kOutput = 6,
  kResized = 7,
  kColors = 8,
  kTitle = 9,
  kPwd = 10,
  kBell = 11,
  kExit = 12,
  kResyncRequired = 13,
  kLaunch = 14,
  kCapability = 15,
  kResizeAck = 16,
  kInput = 100,
  kPaste = 101,
  kViewerSize = 102,
  kReleaseViewer = 103,
  kTerminate = 104,
  kMintCapability = 105,
};

enum class TerminalHostProtocolError {
  kNone,
  kInvalidArgument,
  kInvalidMagic,
  kInvalidVersion,
  kUnknownMessageKind,
  kPayloadTooLarge,
  kTruncated,
  kDecoderFailed,
  kMalformedPayload,
};

struct TerminalHostFrame {
  TerminalHostFrame();
  TerminalHostFrame(const TerminalHostFrame&);
  TerminalHostFrame& operator=(const TerminalHostFrame&);
  TerminalHostFrame(TerminalHostFrame&&);
  TerminalHostFrame& operator=(TerminalHostFrame&&);
  ~TerminalHostFrame();

  uint16_t version = kTerminalHostProtocolVersion;
  TerminalHostMessageKind kind = TerminalHostMessageKind::kOutput;
  uint32_t flags = 0;
  uint64_t request_id = 0;
  uint64_t sequence = 0;
  std::vector<uint8_t> payload;

  bool operator==(const TerminalHostFrame& other) const;
};

struct TerminalHostFrameHeader {
  uint16_t version = 0;
  TerminalHostMessageKind kind = TerminalHostMessageKind::kOutput;
  uint32_t flags = 0;
  size_t payload_length = 0;
  uint64_t request_id = 0;
  uint64_t sequence = 0;
};

// Validates one header without consuming or retaining its payload. Framing
// accepts any nonzero version; semantic version negotiation is enforced by
// ClientHello/HostHello users.
TerminalHostProtocolError DecodeTerminalHostFrameHeader(
    std::string_view bytes,
    size_t max_payload,
    TerminalHostFrameHeader* header);

// Serializes one frame using the fixed 32-byte little-endian header shared
// with cmux-tui. `bytes` is left untouched on failure.
TerminalHostProtocolError EncodeTerminalHostFrame(
    const TerminalHostFrame& frame,
    std::vector<uint8_t>* bytes);

// Incremental stream decoder. A read may end anywhere in a header or payload,
// or contain several frames. Any malformed input poisons the decoder so a
// caller cannot accidentally resume in the middle of an untrusted frame.
class TerminalHostFrameDecoder {
 public:
  explicit TerminalHostFrameDecoder(
      size_t max_payload = kTerminalHostMaxFramePayload);
  TerminalHostFrameDecoder(const TerminalHostFrameDecoder&) = delete;
  TerminalHostFrameDecoder& operator=(const TerminalHostFrameDecoder&) = delete;
  ~TerminalHostFrameDecoder();

  TerminalHostProtocolError Push(std::string_view input,
                                 std::vector<TerminalHostFrame>* frames);
  TerminalHostProtocolError Finish() const;

  size_t buffered_bytes() const { return buffer_.size(); }
  bool failed() const { return failed_; }

 private:
  TerminalHostProtocolError PushInner(std::string_view input,
                                      std::vector<TerminalHostFrame>* frames);

  std::vector<uint8_t> buffer_;
  std::optional<size_t> expected_total_;
  const size_t max_payload_;
  bool failed_ = false;
};

using TerminalHostId = std::array<uint8_t, 16>;
using TerminalHostIncarnation = std::array<uint8_t, 16>;
using TerminalHostCapabilityToken = std::array<uint8_t, 32>;

bool IsValidTerminalHostUuidV4(const std::array<uint8_t, 16>& id);
bool DecodeTerminalHostUuidV4(std::string_view text,
                              std::array<uint8_t, 16>* id);

enum class TerminalHostClientRole : uint8_t {
  kDaemonMirror = 1,
  kRenderer = 2,
  kAdmin = 3,
};

enum class TerminalHostCapabilityRights : uint32_t {
  kNone = 0,
  kRead = 1u << 0,
  kInput = 1u << 1,
  kResize = 1u << 2,
  kTerminate = 1u << 3,
  kMintCapability = 1u << 4,
  kRenderer = (1u << 0) | (1u << 1) | (1u << 2),
  kAdmin = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 4),
};

constexpr TerminalHostCapabilityRights operator|(
    TerminalHostCapabilityRights left,
    TerminalHostCapabilityRights right) {
  return static_cast<TerminalHostCapabilityRights>(
      static_cast<uint32_t>(left) | static_cast<uint32_t>(right));
}

bool AreKnownTerminalHostCapabilityRights(TerminalHostCapabilityRights rights);
bool AreTerminalHostCapabilityRightsAllowedForRole(
    TerminalHostCapabilityRights rights,
    TerminalHostClientRole role);

struct TerminalHostClientHello {
  uint16_t min_version = kTerminalHostProtocolVersion;
  uint16_t max_version = kTerminalHostProtocolVersion;
  TerminalHostClientRole role = TerminalHostClientRole::kRenderer;
  TerminalHostCapabilityRights requested_rights =
      TerminalHostCapabilityRights::kNone;
  TerminalHostId terminal_id{};
  TerminalHostCapabilityToken token{};

  bool operator==(const TerminalHostClientHello& other) const;
};

struct TerminalHostHostHello {
  uint16_t selected_version = kTerminalHostProtocolVersion;
  TerminalHostCapabilityRights granted_rights =
      TerminalHostCapabilityRights::kNone;
  TerminalHostId terminal_id{};
  TerminalHostIncarnation incarnation{};

  bool operator==(const TerminalHostHostHello& other) const;
};

TerminalHostProtocolError EncodeTerminalHostClientHello(
    const TerminalHostClientHello& hello,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostClientHello(
    std::string_view payload,
    TerminalHostClientHello* hello);
TerminalHostProtocolError EncodeTerminalHostHostHello(
    const TerminalHostHostHello& hello,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostHostHello(
    std::string_view payload,
    TerminalHostHostHello* hello);

inline constexpr uint32_t kTerminalHostMaxRendererCapabilityTtlMs = 60 * 1000;

struct TerminalHostMintCapability {
  TerminalHostCapabilityRights rights = TerminalHostCapabilityRights::kRenderer;
  uint32_t ttl_ms = 0;

  bool operator==(const TerminalHostMintCapability& other) const {
    return rights == other.rights && ttl_ms == other.ttl_ms;
  }
};

TerminalHostProtocolError EncodeTerminalHostMintCapability(
    const TerminalHostMintCapability& request,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostMintCapability(
    std::string_view payload,
    TerminalHostMintCapability* request);
TerminalHostProtocolError EncodeTerminalHostCapability(
    const TerminalHostCapabilityToken& token,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostCapability(
    std::string_view payload,
    TerminalHostCapabilityToken* token);

enum class TerminalHostRendererGrantError {
  kNone,
  kInvalidEndpoint,
  kInvalidTerminalId,
  kInvalidIncarnation,
  kInvalidToken,
  kInvalidRights,
  kInvalidTtl,
};

struct TerminalHostRendererGrant {
  std::string endpoint;
  TerminalHostId terminal_id{};
  TerminalHostIncarnation incarnation{};
  TerminalHostCapabilityToken token{};
  TerminalHostCapabilityRights rights = TerminalHostCapabilityRights::kNone;
  uint32_t ttl_ms = 0;
};

// Parses the canonical JSON grant fields without depending on a JSON library.
// IDs are lowercase, unhyphenated UUIDv4 hex; the capability is 32 nonzero
// bytes of lowercase hex; rights must be exactly the renderer set; and the
// response TTL must equal the bounded TTL sent in the request.
TerminalHostRendererGrantError ValidateTerminalHostRendererGrant(
    std::string_view endpoint,
    std::string_view terminal_id,
    std::string_view incarnation,
    std::string_view token,
    uint64_t rights,
    uint64_t ttl_ms,
    uint64_t expected_ttl_ms,
    TerminalHostRendererGrant* grant);
const char* TerminalHostRendererGrantErrorMessage(
    TerminalHostRendererGrantError error);
std::string EncodeTerminalHostId(const TerminalHostId& id);

struct TerminalHostKittyImageAlias {
  uint32_t image_id = 0;
  uint32_t image_number = 0;

  bool operator==(const TerminalHostKittyImageAlias& other) const {
    return image_id == other.image_id && image_number == other.image_number;
  }
};

struct TerminalHostSnapshot {
  TerminalHostSnapshot();
  TerminalHostSnapshot(const TerminalHostSnapshot&);
  TerminalHostSnapshot& operator=(const TerminalHostSnapshot&);
  TerminalHostSnapshot(TerminalHostSnapshot&&);
  TerminalHostSnapshot& operator=(TerminalHostSnapshot&&);
  ~TerminalHostSnapshot();

  uint16_t cols = 80;
  uint16_t rows = 24;
  std::optional<uint32_t> pid;
  std::vector<uint8_t> replay;
  std::optional<std::string> cwd;
  std::vector<std::string> command;
  std::vector<TerminalHostKittyImageAlias> kitty_image_aliases;

  bool operator==(const TerminalHostSnapshot& other) const;
};

TerminalHostProtocolError EncodeTerminalHostSnapshot(
    const TerminalHostSnapshot& snapshot,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostSnapshot(
    std::string_view payload,
    TerminalHostSnapshot* snapshot);

struct TerminalHostResize {
  TerminalHostResize();
  TerminalHostResize(const TerminalHostResize&);
  TerminalHostResize& operator=(const TerminalHostResize&);
  TerminalHostResize(TerminalHostResize&&);
  TerminalHostResize& operator=(TerminalHostResize&&);
  ~TerminalHostResize();

  uint16_t cols = 80;
  uint16_t rows = 24;
  std::vector<uint8_t> replay;
  std::vector<TerminalHostKittyImageAlias> kitty_image_aliases;

  bool operator==(const TerminalHostResize& other) const;
};

TerminalHostProtocolError EncodeTerminalHostResize(
    const TerminalHostResize& resize,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostResize(std::string_view payload,
                                                   TerminalHostResize* resize);

struct TerminalHostResizeAck {
  uint16_t cols = 80;
  uint16_t rows = 24;
  uint32_t result_flags = 0;

  bool operator==(const TerminalHostResizeAck& other) const;
};

TerminalHostProtocolError EncodeTerminalHostResizeAck(
    const TerminalHostResizeAck& ack,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostResizeAck(
    std::string_view payload,
    TerminalHostResizeAck* ack);

struct TerminalHostRgb {
  uint8_t red = 0;
  uint8_t green = 0;
  uint8_t blue = 0;

  bool operator==(const TerminalHostRgb& other) const;
};

struct TerminalHostPaletteEntry {
  uint8_t index = 0;
  TerminalHostRgb color;

  bool operator==(const TerminalHostPaletteEntry& other) const;
};

// Wire values are deliberately shape-only. Blinking is carried atomically in
// TerminalHostCursorVisual so a receiver never observes half a cursor update.
enum class TerminalHostCursorStyle : uint8_t {
  kBlock = 1,
  kUnderline = 2,
  kBar = 3,
};

struct TerminalHostCursorVisual {
  TerminalHostCursorStyle style = TerminalHostCursorStyle::kBlock;
  bool blinking = true;

  bool operator==(const TerminalHostCursorVisual& other) const;
};

// A complete sparse application-authored color state plus the authoritative
// effective cursor visual. Missing color defaults and palette indices mean
// reset to the receiving renderer's configured theme, never retain the
// preceding override. Version 2 Colors payloads always carry cursor_visual so
// DECSCUSR, alternate-screen restoration, and DEC mode 12 resolve to one
// atomic shape/blink pair. Version 1 payloads decode with cursor_visual absent.
struct TerminalHostColors {
  TerminalHostColors();
  TerminalHostColors(const TerminalHostColors&);
  TerminalHostColors& operator=(const TerminalHostColors&);
  TerminalHostColors(TerminalHostColors&&);
  TerminalHostColors& operator=(TerminalHostColors&&);
  ~TerminalHostColors();

  std::optional<TerminalHostRgb> foreground;
  std::optional<TerminalHostRgb> background;
  std::optional<TerminalHostRgb> cursor;
  std::optional<TerminalHostCursorVisual> cursor_visual;
  std::vector<TerminalHostPaletteEntry> palette;

  bool operator==(const TerminalHostColors& other) const;
};

TerminalHostProtocolError EncodeTerminalHostColors(
    const TerminalHostColors& colors,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostColors(std::string_view payload,
                                                   TerminalHostColors* colors);

// Appends one complete sparse color/cursor state as Ghostty-compatible OSC and
// DECSCUSR metadata. Missing color fields reset rather than retaining prior
// state: palette first resets with OSC 104, then sparse OSC 4 entries are
// applied; defaults use OSC 10/11/12 or OSC 110/111/112 resets. A present v2
// cursor visual first resets with DECSCUSR 0, then applies the authoritative
// block/underline/bar plus blinking pair. An absent legacy-v1 cursor visual is
// unknown and appends no cursor bytes, preserving cursor state established by
// the replay or live Output. Existing bytes are preserved for atomic
// Output+Colors and replay+Colors publication.
void AppendTerminalHostColorMetadata(const TerminalHostColors& colors,
                                     std::vector<uint8_t>* bytes);

// Validates and copies one UTF-8 metadata payload (Title or Pwd).
TerminalHostProtocolError DecodeTerminalHostUtf8(std::string_view payload,
                                                 std::string* text);

TerminalHostProtocolError EncodeTerminalHostViewerSize(
    uint16_t cols,
    uint16_t rows,
    std::vector<uint8_t>* payload);
TerminalHostProtocolError DecodeTerminalHostViewerSize(std::string_view payload,
                                                       uint16_t* cols,
                                                       uint16_t* rows);

}  // namespace cmux

#endif  // CHROME_SERVICES_CMUX_TERMINAL_RENDERER_PUBLIC_CPP_CMUX_TERMINAL_HOST_PROTOCOL_H_
