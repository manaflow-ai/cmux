// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "chrome/services/cmux_terminal_renderer/public/cpp/cmux_terminal_host_protocol.h"

#include <algorithm>
#include <iterator>
#include <limits>
#include <unordered_set>
#include <utility>

namespace cmux {
namespace {

constexpr size_t kClientHelloLength = 60;
constexpr size_t kHostHelloLength = 40;

void AppendU16(std::vector<uint8_t>* output, uint16_t value) {
  output->push_back(static_cast<uint8_t>(value));
  output->push_back(static_cast<uint8_t>(value >> 8));
}

void AppendU32(std::vector<uint8_t>* output, uint32_t value) {
  for (size_t index = 0; index < sizeof(value); ++index) {
    output->push_back(static_cast<uint8_t>(value >> (index * 8)));
  }
}

void AppendU64(std::vector<uint8_t>* output, uint64_t value) {
  for (size_t index = 0; index < sizeof(value); ++index) {
    output->push_back(static_cast<uint8_t>(value >> (index * 8)));
  }
}

uint16_t ReadU16(std::string_view bytes, size_t offset) {
  return static_cast<uint16_t>(static_cast<uint8_t>(bytes[offset])) |
         static_cast<uint16_t>(static_cast<uint8_t>(bytes[offset + 1])) << 8;
}

uint32_t ReadU32(std::string_view bytes, size_t offset) {
  uint32_t value = 0;
  for (size_t index = 0; index < sizeof(value); ++index) {
    value |= static_cast<uint32_t>(static_cast<uint8_t>(bytes[offset + index]))
             << (index * 8);
  }
  return value;
}

uint64_t ReadU64(std::string_view bytes, size_t offset) {
  uint64_t value = 0;
  for (size_t index = 0; index < sizeof(value); ++index) {
    value |= static_cast<uint64_t>(static_cast<uint8_t>(bytes[offset + index]))
             << (index * 8);
  }
  return value;
}

std::optional<TerminalHostMessageKind> ParseMessageKind(uint16_t value) {
  switch (value) {
    case 1:
      return TerminalHostMessageKind::kBootstrap;
    case 2:
      return TerminalHostMessageKind::kReady;
    case 3:
      return TerminalHostMessageKind::kClientHello;
    case 4:
      return TerminalHostMessageKind::kHostHello;
    case 5:
      return TerminalHostMessageKind::kSnapshot;
    case 6:
      return TerminalHostMessageKind::kOutput;
    case 7:
      return TerminalHostMessageKind::kResized;
    case 8:
      return TerminalHostMessageKind::kColors;
    case 9:
      return TerminalHostMessageKind::kTitle;
    case 10:
      return TerminalHostMessageKind::kPwd;
    case 11:
      return TerminalHostMessageKind::kBell;
    case 12:
      return TerminalHostMessageKind::kExit;
    case 13:
      return TerminalHostMessageKind::kResyncRequired;
    case 14:
      return TerminalHostMessageKind::kLaunch;
    case 15:
      return TerminalHostMessageKind::kCapability;
    case 16:
      return TerminalHostMessageKind::kResizeAck;
    case 100:
      return TerminalHostMessageKind::kInput;
    case 101:
      return TerminalHostMessageKind::kPaste;
    case 102:
      return TerminalHostMessageKind::kViewerSize;
    case 103:
      return TerminalHostMessageKind::kReleaseViewer;
    case 104:
      return TerminalHostMessageKind::kTerminate;
    case 105:
      return TerminalHostMessageKind::kMintCapability;
    default:
      return std::nullopt;
  }
}

TerminalHostProtocolError ParseHeader(std::string_view bytes,
                                      size_t max_payload,
                                      TerminalHostFrameHeader* header) {
  if (!header || bytes.size() != kTerminalHostHeaderLength) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  for (size_t index = 0; index < kTerminalHostMagic.size(); ++index) {
    if (static_cast<uint8_t>(bytes[index]) != kTerminalHostMagic[index]) {
      return TerminalHostProtocolError::kInvalidMagic;
    }
  }
  const uint16_t version = ReadU16(bytes, 4);
  if (version == 0) {
    return TerminalHostProtocolError::kInvalidVersion;
  }
  const std::optional<TerminalHostMessageKind> kind =
      ParseMessageKind(ReadU16(bytes, 6));
  if (!kind) {
    return TerminalHostProtocolError::kUnknownMessageKind;
  }
  const size_t payload_length = ReadU32(bytes, 12);
  if (payload_length > max_payload) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  *header = TerminalHostFrameHeader{version,
                                    *kind,
                                    ReadU32(bytes, 8),
                                    payload_length,
                                    ReadU64(bytes, 16),
                                    ReadU64(bytes, 24)};
  return TerminalHostProtocolError::kNone;
}

bool IsValidUtf8(std::string_view text) {
  size_t index = 0;
  while (index < text.size()) {
    const uint8_t first = static_cast<uint8_t>(text[index]);
    if (first <= 0x7f) {
      ++index;
      continue;
    }

    size_t continuation_count = 0;
    uint32_t code_point = 0;
    uint32_t minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) {
      continuation_count = 1;
      code_point = first & 0x1f;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation_count = 2;
      code_point = first & 0x0f;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation_count = 3;
      code_point = first & 0x07;
      minimum = 0x10000;
    } else {
      return false;
    }
    if (continuation_count > text.size() - index - 1) {
      return false;
    }
    for (size_t continuation = 1; continuation <= continuation_count;
         ++continuation) {
      const uint8_t byte = static_cast<uint8_t>(text[index + continuation]);
      if ((byte & 0xc0) != 0x80) {
        return false;
      }
      code_point = (code_point << 6) | (byte & 0x3f);
    }
    if (code_point < minimum || code_point > 0x10ffff ||
        (code_point >= 0xd800 && code_point <= 0xdfff)) {
      return false;
    }
    index += continuation_count + 1;
  }
  return true;
}

class PayloadReader {
 public:
  explicit PayloadReader(std::string_view payload) : payload_(payload) {}

  bool Take(size_t length, std::string_view* bytes) {
    if (!bytes || length > payload_.size() - offset_) {
      return false;
    }
    *bytes = payload_.substr(offset_, length);
    offset_ += length;
    return true;
  }

  bool U8(uint8_t* value) {
    std::string_view bytes;
    if (!value || !Take(1, &bytes)) {
      return false;
    }
    *value = static_cast<uint8_t>(bytes[0]);
    return true;
  }

  bool U16(uint16_t* value) {
    std::string_view bytes;
    if (!value || !Take(2, &bytes)) {
      return false;
    }
    *value = ReadU16(bytes, 0);
    return true;
  }

  bool U32(uint32_t* value) {
    std::string_view bytes;
    if (!value || !Take(4, &bytes)) {
      return false;
    }
    *value = ReadU32(bytes, 0);
    return true;
  }

  bool Bytes(size_t limit, std::string_view* bytes) {
    uint32_t length = 0;
    return U32(&length) && length <= limit && Take(length, bytes);
  }

  bool String(std::string* value) {
    std::string_view bytes;
    if (!value || !Bytes(kTerminalHostMaxString, &bytes) ||
        !IsValidUtf8(bytes)) {
      return false;
    }
    value->assign(bytes);
    return true;
  }

  bool OptionalString(std::optional<std::string>* value) {
    uint8_t tag = 0;
    if (!value || !U8(&tag)) {
      return false;
    }
    if (tag == 0) {
      value->reset();
      return true;
    }
    if (tag != 1) {
      return false;
    }
    std::string text;
    if (!String(&text)) {
      return false;
    }
    *value = std::move(text);
    return true;
  }

  bool finished() const { return offset_ == payload_.size(); }

 private:
  const std::string_view payload_;
  size_t offset_ = 0;
};

TerminalHostProtocolError ValidateKittyImageAliases(
    const std::vector<TerminalHostKittyImageAlias>& aliases) {
  if (aliases.size() > kTerminalHostMaxKittyImageAliases) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  // Repeated image numbers preserve Kitty's assignment history. Image IDs
  // remain unique identities within a snapshot.
  std::unordered_set<uint32_t> image_ids;
  image_ids.reserve(aliases.size());
  for (const TerminalHostKittyImageAlias& alias : aliases) {
    if (alias.image_id == 0 || alias.image_number == 0 ||
        !image_ids.insert(alias.image_id).second) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
  }
  return TerminalHostProtocolError::kNone;
}

void AppendKittyImageAliases(
    std::vector<uint8_t>* output,
    const std::vector<TerminalHostKittyImageAlias>& aliases) {
  AppendU16(output, static_cast<uint16_t>(aliases.size()));
  for (const TerminalHostKittyImageAlias& alias : aliases) {
    AppendU32(output, alias.image_id);
    AppendU32(output, alias.image_number);
  }
}

TerminalHostProtocolError ReadKittyImageAliases(
    PayloadReader* reader,
    std::vector<TerminalHostKittyImageAlias>* aliases) {
  uint16_t count = 0;
  if (!reader || !aliases || !reader->U16(&count) ||
      count > kTerminalHostMaxKittyImageAliases) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::vector<TerminalHostKittyImageAlias> decoded;
  decoded.reserve(count);
  for (size_t index = 0; index < count; ++index) {
    TerminalHostKittyImageAlias alias;
    if (!reader->U32(&alias.image_id) ||
        !reader->U32(&alias.image_number)) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
    decoded.push_back(alias);
  }
  if (ValidateKittyImageAliases(decoded) !=
      TerminalHostProtocolError::kNone) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  *aliases = std::move(decoded);
  return TerminalHostProtocolError::kNone;
}

bool AppendBytes(std::vector<uint8_t>* output,
                 std::string_view bytes,
                 size_t limit) {
  if (bytes.size() > limit ||
      bytes.size() > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  AppendU32(output, static_cast<uint32_t>(bytes.size()));
  output->insert(output->end(), bytes.begin(), bytes.end());
  return true;
}

bool AppendString(std::vector<uint8_t>* output, std::string_view text) {
  return IsValidUtf8(text) && AppendBytes(output, text, kTerminalHostMaxString);
}

bool AppendOptionalString(std::vector<uint8_t>* output,
                          const std::optional<std::string>& text) {
  output->push_back(text ? 1 : 0);
  return !text || AppendString(output, *text);
}

bool ParseClientRole(uint8_t value, TerminalHostClientRole* role) {
  if (!role) {
    return false;
  }
  switch (value) {
    case 1:
      *role = TerminalHostClientRole::kDaemonMirror;
      return true;
    case 2:
      *role = TerminalHostClientRole::kRenderer;
      return true;
    case 3:
      *role = TerminalHostClientRole::kAdmin;
      return true;
    default:
      return false;
  }
}

bool IsKnownClientRole(TerminalHostClientRole role) {
  TerminalHostClientRole parsed;
  return ParseClientRole(static_cast<uint8_t>(role), &parsed);
}

template <size_t N>
void AppendArray(std::vector<uint8_t>* output,
                 const std::array<uint8_t, N>& value) {
  output->insert(output->end(), value.begin(), value.end());
}

template <size_t N>
bool ReadArray(PayloadReader* reader, std::array<uint8_t, N>* value) {
  std::string_view bytes;
  if (!reader || !value || !reader->Take(N, &bytes)) {
    return false;
  }
  std::copy(bytes.begin(), bytes.end(), value->begin());
  return true;
}

template <size_t N>
bool DecodeLowerHex(std::string_view text, std::array<uint8_t, N>* bytes) {
  if (!bytes || text.size() != N * 2) {
    return false;
  }
  std::array<uint8_t, N> decoded{};
  for (size_t index = 0; index < N; ++index) {
    const auto nibble = [](char character) -> std::optional<uint8_t> {
      if (character >= '0' && character <= '9') {
        return static_cast<uint8_t>(character - '0');
      }
      if (character >= 'a' && character <= 'f') {
        return static_cast<uint8_t>(character - 'a' + 10);
      }
      return std::nullopt;
    };
    const std::optional<uint8_t> high = nibble(text[index * 2]);
    const std::optional<uint8_t> low = nibble(text[index * 2 + 1]);
    if (!high || !low) {
      return false;
    }
    decoded[index] = static_cast<uint8_t>((*high << 4) | *low);
  }
  *bytes = decoded;
  return true;
}

bool IsUuidV4(const std::array<uint8_t, 16>& id) {
  return (id[6] & 0xf0) == 0x40 && (id[8] & 0xc0) == 0x80;
}

bool IsCanonicalRendererEndpoint(std::string_view endpoint) {
  // sockaddr_un::sun_path is 104 bytes on macOS including the terminator.
  // The Rust host deliberately uses this portable, short /tmp namespace.
  constexpr size_t kMaxEndpointBytes = 103;
  constexpr std::string_view kPrefix = "/tmp/cmux-th-";
  if (endpoint.size() <= kPrefix.size() ||
      endpoint.size() > kMaxEndpointBytes ||
      endpoint.find('\0') != std::string_view::npos ||
      endpoint.substr(0, kPrefix.size()) != kPrefix) {
    return false;
  }
  const size_t separator = endpoint.find('/', kPrefix.size());
  if (separator == std::string_view::npos || separator == kPrefix.size() ||
      endpoint.find('/', separator + 1) != std::string_view::npos) {
    return false;
  }
  for (const char character :
       endpoint.substr(kPrefix.size(), separator - kPrefix.size())) {
    if (character < '0' || character > '9') {
      return false;
    }
  }
  const std::string_view name = endpoint.substr(separator + 1);
  constexpr std::string_view kSuffix = ".sock";
  return name.size() > kSuffix.size() &&
         name.substr(name.size() - kSuffix.size()) == kSuffix;
}

template <size_t N>
std::string EncodeLowerHex(const std::array<uint8_t, N>& bytes) {
  constexpr std::array<char, 16> kDigits = {
      '0', '1', '2', '3', '4', '5', '6', '7',
      '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
  std::string encoded;
  encoded.resize(N * 2);
  for (size_t index = 0; index < N; ++index) {
    encoded[index * 2] = kDigits[bytes[index] >> 4];
    encoded[index * 2 + 1] = kDigits[bytes[index] & 0x0f];
  }
  return encoded;
}

}  // namespace

TerminalHostFrame::TerminalHostFrame() = default;
TerminalHostFrame::TerminalHostFrame(const TerminalHostFrame&) = default;
TerminalHostFrame& TerminalHostFrame::operator=(const TerminalHostFrame&) =
    default;
TerminalHostFrame::TerminalHostFrame(TerminalHostFrame&&) = default;
TerminalHostFrame& TerminalHostFrame::operator=(TerminalHostFrame&&) = default;
TerminalHostFrame::~TerminalHostFrame() = default;

TerminalHostProtocolError DecodeTerminalHostFrameHeader(
    std::string_view bytes,
    size_t max_payload,
    TerminalHostFrameHeader* header) {
  return ParseHeader(bytes, std::min(max_payload, kTerminalHostMaxFramePayload),
                     header);
}

bool TerminalHostFrame::operator==(const TerminalHostFrame& other) const {
  return version == other.version && kind == other.kind &&
         flags == other.flags && request_id == other.request_id &&
         sequence == other.sequence && payload == other.payload;
}

TerminalHostProtocolError EncodeTerminalHostFrame(
    const TerminalHostFrame& frame,
    std::vector<uint8_t>* bytes) {
  if (!bytes) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (frame.version == 0) {
    return TerminalHostProtocolError::kInvalidVersion;
  }
  if (!ParseMessageKind(static_cast<uint16_t>(frame.kind))) {
    return TerminalHostProtocolError::kUnknownMessageKind;
  }
  if (frame.payload.size() > kTerminalHostMaxFramePayload ||
      frame.payload.size() > std::numeric_limits<uint32_t>::max()) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }

  std::vector<uint8_t> encoded;
  encoded.reserve(kTerminalHostHeaderLength + frame.payload.size());
  encoded.insert(encoded.end(), kTerminalHostMagic.begin(),
                 kTerminalHostMagic.end());
  AppendU16(&encoded, frame.version);
  AppendU16(&encoded, static_cast<uint16_t>(frame.kind));
  AppendU32(&encoded, frame.flags);
  AppendU32(&encoded, static_cast<uint32_t>(frame.payload.size()));
  AppendU64(&encoded, frame.request_id);
  AppendU64(&encoded, frame.sequence);
  encoded.insert(encoded.end(), frame.payload.begin(), frame.payload.end());
  *bytes = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostFrameDecoder::TerminalHostFrameDecoder(size_t max_payload)
    : max_payload_(std::min(max_payload, kTerminalHostMaxFramePayload)) {
  buffer_.reserve(kTerminalHostHeaderLength);
}

TerminalHostFrameDecoder::~TerminalHostFrameDecoder() = default;

TerminalHostProtocolError TerminalHostFrameDecoder::Push(
    std::string_view input,
    std::vector<TerminalHostFrame>* frames) {
  if (!frames) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (failed_) {
    return TerminalHostProtocolError::kDecoderFailed;
  }
  std::vector<TerminalHostFrame> decoded;
  const TerminalHostProtocolError result = PushInner(input, &decoded);
  if (result != TerminalHostProtocolError::kNone) {
    failed_ = true;
    return result;
  }
  frames->insert(frames->end(), std::make_move_iterator(decoded.begin()),
                 std::make_move_iterator(decoded.end()));
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError TerminalHostFrameDecoder::PushInner(
    std::string_view input,
    std::vector<TerminalHostFrame>* frames) {
  while (true) {
    if (!expected_total_) {
      const size_t needed = kTerminalHostHeaderLength - buffer_.size();
      const size_t count = std::min(needed, input.size());
      buffer_.insert(buffer_.end(), input.begin(), input.begin() + count);
      input.remove_prefix(count);
      if (buffer_.size() < kTerminalHostHeaderLength) {
        return TerminalHostProtocolError::kNone;
      }
      TerminalHostFrameHeader header;
      const TerminalHostProtocolError result = ParseHeader(
          std::string_view(reinterpret_cast<const char*>(buffer_.data()),
                           kTerminalHostHeaderLength),
          max_payload_, &header);
      if (result != TerminalHostProtocolError::kNone) {
        return result;
      }
      expected_total_ = kTerminalHostHeaderLength + header.payload_length;
      buffer_.reserve(*expected_total_);
    }

    const size_t needed = *expected_total_ - buffer_.size();
    const size_t count = std::min(needed, input.size());
    buffer_.insert(buffer_.end(), input.begin(), input.begin() + count);
    input.remove_prefix(count);
    if (buffer_.size() < *expected_total_) {
      return TerminalHostProtocolError::kNone;
    }

    TerminalHostFrameHeader header;
    const TerminalHostProtocolError result = ParseHeader(
        std::string_view(reinterpret_cast<const char*>(buffer_.data()),
                         kTerminalHostHeaderLength),
        max_payload_, &header);
    if (result != TerminalHostProtocolError::kNone) {
      return result;
    }
    TerminalHostFrame frame;
    frame.version = header.version;
    frame.kind = header.kind;
    frame.flags = header.flags;
    frame.request_id = header.request_id;
    frame.sequence = header.sequence;
    frame.payload.assign(buffer_.begin() + kTerminalHostHeaderLength,
                         buffer_.end());
    frames->push_back(std::move(frame));

    std::vector<uint8_t>().swap(buffer_);
    buffer_.reserve(kTerminalHostHeaderLength);
    expected_total_.reset();
    if (input.empty()) {
      return TerminalHostProtocolError::kNone;
    }
  }
}

TerminalHostProtocolError TerminalHostFrameDecoder::Finish() const {
  if (failed_) {
    return TerminalHostProtocolError::kDecoderFailed;
  }
  if (buffer_.empty() && !expected_total_) {
    return TerminalHostProtocolError::kNone;
  }
  return TerminalHostProtocolError::kTruncated;
}

bool AreKnownTerminalHostCapabilityRights(TerminalHostCapabilityRights rights) {
  const uint32_t bits = static_cast<uint32_t>(rights);
  return (bits &
          ~static_cast<uint32_t>(TerminalHostCapabilityRights::kAdmin)) == 0;
}

bool IsValidTerminalHostUuidV4(const std::array<uint8_t, 16>& id) {
  return IsUuidV4(id);
}

bool DecodeTerminalHostUuidV4(std::string_view text,
                              std::array<uint8_t, 16>* id) {
  if (!id) {
    return false;
  }
  std::array<uint8_t, 16> decoded{};
  if (!DecodeLowerHex(text, &decoded) || !IsUuidV4(decoded)) {
    return false;
  }
  *id = decoded;
  return true;
}

bool AreTerminalHostCapabilityRightsAllowedForRole(
    TerminalHostCapabilityRights rights,
    TerminalHostClientRole role) {
  if (!AreKnownTerminalHostCapabilityRights(rights)) {
    return false;
  }
  TerminalHostCapabilityRights allowed;
  switch (role) {
    case TerminalHostClientRole::kDaemonMirror:
      allowed = TerminalHostCapabilityRights::kRead;
      break;
    case TerminalHostClientRole::kRenderer:
      allowed = TerminalHostCapabilityRights::kRead |
                TerminalHostCapabilityRights::kInput |
                TerminalHostCapabilityRights::kResize;
      break;
    case TerminalHostClientRole::kAdmin:
      allowed = TerminalHostCapabilityRights::kAdmin;
      break;
    default:
      return false;
  }
  return (static_cast<uint32_t>(rights) & ~static_cast<uint32_t>(allowed)) == 0;
}

bool TerminalHostClientHello::operator==(
    const TerminalHostClientHello& other) const {
  return min_version == other.min_version && max_version == other.max_version &&
         role == other.role && requested_rights == other.requested_rights &&
         terminal_id == other.terminal_id && token == other.token;
}

bool TerminalHostHostHello::operator==(
    const TerminalHostHostHello& other) const {
  return selected_version == other.selected_version &&
         granted_rights == other.granted_rights &&
         terminal_id == other.terminal_id && incarnation == other.incarnation;
}

TerminalHostProtocolError EncodeTerminalHostClientHello(
    const TerminalHostClientHello& hello,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (!IsKnownClientRole(hello.role) ||
      !AreKnownTerminalHostCapabilityRights(hello.requested_rights)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(kClientHelloLength);
  AppendU16(&encoded, hello.min_version);
  AppendU16(&encoded, hello.max_version);
  encoded.push_back(static_cast<uint8_t>(hello.role));
  encoded.insert(encoded.end(), 3, 0);
  AppendU32(&encoded, static_cast<uint32_t>(hello.requested_rights));
  AppendArray(&encoded, hello.terminal_id);
  AppendArray(&encoded, hello.token);
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostClientHello(
    std::string_view payload,
    TerminalHostClientHello* hello) {
  if (!hello) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != kClientHelloLength || payload[5] != 0 ||
      payload[6] != 0 || payload[7] != 0) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  TerminalHostClientHello decoded;
  decoded.min_version = ReadU16(payload, 0);
  decoded.max_version = ReadU16(payload, 2);
  if (!ParseClientRole(static_cast<uint8_t>(payload[4]), &decoded.role)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  decoded.requested_rights =
      static_cast<TerminalHostCapabilityRights>(ReadU32(payload, 8));
  if (!AreKnownTerminalHostCapabilityRights(decoded.requested_rights)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::copy(payload.begin() + 12, payload.begin() + 28,
            decoded.terminal_id.begin());
  std::copy(payload.begin() + 28, payload.end(), decoded.token.begin());
  *hello = decoded;
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError EncodeTerminalHostHostHello(
    const TerminalHostHostHello& hello,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (!AreKnownTerminalHostCapabilityRights(hello.granted_rights)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(kHostHelloLength);
  AppendU16(&encoded, hello.selected_version);
  AppendU16(&encoded, 0);
  AppendU32(&encoded, static_cast<uint32_t>(hello.granted_rights));
  AppendArray(&encoded, hello.terminal_id);
  AppendArray(&encoded, hello.incarnation);
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostHostHello(
    std::string_view payload,
    TerminalHostHostHello* hello) {
  if (!hello) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != kHostHelloLength || payload[2] != 0 ||
      payload[3] != 0) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  TerminalHostHostHello decoded;
  decoded.selected_version = ReadU16(payload, 0);
  decoded.granted_rights =
      static_cast<TerminalHostCapabilityRights>(ReadU32(payload, 4));
  if (!AreKnownTerminalHostCapabilityRights(decoded.granted_rights)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::copy(payload.begin() + 8, payload.begin() + 24,
            decoded.terminal_id.begin());
  std::copy(payload.begin() + 24, payload.end(), decoded.incarnation.begin());
  *hello = decoded;
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError EncodeTerminalHostMintCapability(
    const TerminalHostMintCapability& request,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  const uint32_t rights = static_cast<uint32_t>(request.rights);
  const uint32_t renderer =
      static_cast<uint32_t>(TerminalHostCapabilityRights::kRenderer);
  if (!AreKnownTerminalHostCapabilityRights(request.rights) ||
      (rights & static_cast<uint32_t>(TerminalHostCapabilityRights::kRead)) ==
          0 ||
      (rights & ~renderer) != 0 || request.ttl_ms == 0 ||
      request.ttl_ms > kTerminalHostMaxRendererCapabilityTtlMs) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(8);
  AppendU32(&encoded, rights);
  AppendU32(&encoded, request.ttl_ms);
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostMintCapability(
    std::string_view payload,
    TerminalHostMintCapability* request) {
  if (!request) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != 8) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  TerminalHostMintCapability decoded;
  decoded.rights =
      static_cast<TerminalHostCapabilityRights>(ReadU32(payload, 0));
  decoded.ttl_ms = ReadU32(payload, 4);
  std::vector<uint8_t> canonical;
  if (EncodeTerminalHostMintCapability(decoded, &canonical) !=
      TerminalHostProtocolError::kNone) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  *request = decoded;
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError EncodeTerminalHostCapability(
    const TerminalHostCapabilityToken& token,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  *payload = std::vector<uint8_t>(token.begin(), token.end());
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostCapability(
    std::string_view payload,
    TerminalHostCapabilityToken* token) {
  if (!token) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != token->size()) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::copy(payload.begin(), payload.end(), token->begin());
  return TerminalHostProtocolError::kNone;
}

TerminalHostRendererGrantError ValidateTerminalHostRendererGrant(
    std::string_view endpoint,
    std::string_view terminal_id,
    std::string_view incarnation,
    std::string_view token,
    uint64_t rights,
    uint64_t ttl_ms,
    uint64_t expected_ttl_ms,
    TerminalHostRendererGrant* grant) {
  if (!grant || !IsCanonicalRendererEndpoint(endpoint)) {
    return TerminalHostRendererGrantError::kInvalidEndpoint;
  }
  TerminalHostRendererGrant decoded;
  if (!DecodeLowerHex(terminal_id, &decoded.terminal_id) ||
      !IsUuidV4(decoded.terminal_id)) {
    return TerminalHostRendererGrantError::kInvalidTerminalId;
  }
  if (!DecodeLowerHex(incarnation, &decoded.incarnation) ||
      !IsUuidV4(decoded.incarnation)) {
    return TerminalHostRendererGrantError::kInvalidIncarnation;
  }
  if (!DecodeLowerHex(token, &decoded.token) ||
      std::all_of(decoded.token.begin(), decoded.token.end(),
                  [](uint8_t byte) { return byte == 0; })) {
    return TerminalHostRendererGrantError::kInvalidToken;
  }
  constexpr uint32_t kRendererRights =
      static_cast<uint32_t>(TerminalHostCapabilityRights::kRenderer);
  if (rights != kRendererRights) {
    return TerminalHostRendererGrantError::kInvalidRights;
  }
  if (ttl_ms == 0 || ttl_ms > kTerminalHostMaxRendererCapabilityTtlMs ||
      expected_ttl_ms == 0 ||
      expected_ttl_ms > kTerminalHostMaxRendererCapabilityTtlMs ||
      ttl_ms != expected_ttl_ms) {
    return TerminalHostRendererGrantError::kInvalidTtl;
  }
  const std::string expected_name =
      EncodeLowerHex(decoded.terminal_id) + ".sock";
  if (endpoint.substr(endpoint.rfind('/') + 1) != expected_name) {
    return TerminalHostRendererGrantError::kInvalidEndpoint;
  }
  decoded.endpoint = std::string(endpoint);
  decoded.rights = TerminalHostCapabilityRights::kRenderer;
  decoded.ttl_ms = static_cast<uint32_t>(ttl_ms);
  *grant = std::move(decoded);
  return TerminalHostRendererGrantError::kNone;
}

const char* TerminalHostRendererGrantErrorMessage(
    TerminalHostRendererGrantError error) {
  switch (error) {
    case TerminalHostRendererGrantError::kNone:
      return "";
    case TerminalHostRendererGrantError::kInvalidEndpoint:
      return "invalid terminal-host endpoint";
    case TerminalHostRendererGrantError::kInvalidTerminalId:
      return "invalid terminal-host terminal UUID";
    case TerminalHostRendererGrantError::kInvalidIncarnation:
      return "invalid terminal-host incarnation UUID";
    case TerminalHostRendererGrantError::kInvalidToken:
      return "invalid terminal-host one-use token";
    case TerminalHostRendererGrantError::kInvalidRights:
      return "invalid terminal-host renderer rights";
    case TerminalHostRendererGrantError::kInvalidTtl:
      return "invalid terminal-host renderer TTL";
  }
  return "unknown terminal-host renderer grant error";
}

std::string EncodeTerminalHostId(const TerminalHostId& id) {
  return EncodeLowerHex(id);
}

TerminalHostSnapshot::TerminalHostSnapshot() = default;
TerminalHostSnapshot::TerminalHostSnapshot(const TerminalHostSnapshot&) =
    default;
TerminalHostSnapshot& TerminalHostSnapshot::operator=(
    const TerminalHostSnapshot&) = default;
TerminalHostSnapshot::TerminalHostSnapshot(TerminalHostSnapshot&&) = default;
TerminalHostSnapshot& TerminalHostSnapshot::operator=(TerminalHostSnapshot&&) =
    default;
TerminalHostSnapshot::~TerminalHostSnapshot() = default;

bool TerminalHostSnapshot::operator==(const TerminalHostSnapshot& other) const {
  return cols == other.cols && rows == other.rows && pid == other.pid &&
         replay == other.replay && cwd == other.cwd &&
         command == other.command &&
         kitty_image_aliases == other.kitty_image_aliases;
}

TerminalHostProtocolError EncodeTerminalHostSnapshot(
    const TerminalHostSnapshot& snapshot,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (snapshot.replay.size() > kTerminalHostMaxSnapshotReplay ||
      snapshot.command.size() > kTerminalHostMaxCommandArguments) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  const TerminalHostProtocolError aliases_error =
      ValidateKittyImageAliases(snapshot.kitty_image_aliases);
  if (aliases_error != TerminalHostProtocolError::kNone) {
    return aliases_error;
  }
  std::vector<uint8_t> encoded;
  AppendU16(&encoded, snapshot.cols);
  AppendU16(&encoded, snapshot.rows);
  AppendU32(&encoded, snapshot.pid.value_or(0));
  if (!AppendBytes(&encoded,
                   std::string_view(
                       reinterpret_cast<const char*>(snapshot.replay.data()),
                       snapshot.replay.size()),
                   kTerminalHostMaxSnapshotReplay) ||
      !AppendOptionalString(&encoded, snapshot.cwd)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  AppendU16(&encoded, static_cast<uint16_t>(snapshot.command.size()));
  for (const std::string& argument : snapshot.command) {
    if (!AppendString(&encoded, argument)) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
  }
  AppendKittyImageAliases(&encoded, snapshot.kitty_image_aliases);
  if (encoded.size() > kTerminalHostMaxFramePayload) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostSnapshot(
    std::string_view payload,
    TerminalHostSnapshot* snapshot) {
  if (!snapshot) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() > kTerminalHostMaxFramePayload) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  PayloadReader reader(payload);
  TerminalHostSnapshot decoded;
  uint32_t pid = 0;
  std::string_view replay;
  if (!reader.U16(&decoded.cols) || !reader.U16(&decoded.rows) ||
      !reader.U32(&pid) ||
      !reader.Bytes(kTerminalHostMaxSnapshotReplay, &replay)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  decoded.cols = std::max<uint16_t>(decoded.cols, 1);
  decoded.rows = std::max<uint16_t>(decoded.rows, 1);
  if (pid != 0) {
    decoded.pid = pid;
  }
  decoded.replay.assign(replay.begin(), replay.end());
  if (!reader.OptionalString(&decoded.cwd)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  uint16_t argument_count = 0;
  if (!reader.U16(&argument_count) ||
      argument_count > kTerminalHostMaxCommandArguments) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  decoded.command.reserve(argument_count);
  for (size_t index = 0; index < argument_count; ++index) {
    std::string argument;
    if (!reader.String(&argument)) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
    decoded.command.push_back(std::move(argument));
  }
  if (ReadKittyImageAliases(&reader, &decoded.kitty_image_aliases) !=
          TerminalHostProtocolError::kNone ||
      !reader.finished()) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  *snapshot = std::move(decoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostResize::TerminalHostResize() = default;
TerminalHostResize::TerminalHostResize(const TerminalHostResize&) = default;
TerminalHostResize& TerminalHostResize::operator=(const TerminalHostResize&) =
    default;
TerminalHostResize::TerminalHostResize(TerminalHostResize&&) = default;
TerminalHostResize& TerminalHostResize::operator=(TerminalHostResize&&) =
    default;
TerminalHostResize::~TerminalHostResize() = default;

bool TerminalHostResize::operator==(const TerminalHostResize& other) const {
  return cols == other.cols && rows == other.rows &&
         replay == other.replay &&
         kitty_image_aliases == other.kitty_image_aliases;
}

TerminalHostProtocolError EncodeTerminalHostResize(
    const TerminalHostResize& resize,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (resize.replay.size() > kTerminalHostMaxSnapshotReplay) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  const TerminalHostProtocolError aliases_error =
      ValidateKittyImageAliases(resize.kitty_image_aliases);
  if (aliases_error != TerminalHostProtocolError::kNone) {
    return aliases_error;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(10 + resize.replay.size() +
                  resize.kitty_image_aliases.size() * 8);
  AppendU16(&encoded, resize.cols);
  AppendU16(&encoded, resize.rows);
  AppendU32(&encoded, static_cast<uint32_t>(resize.replay.size()));
  encoded.insert(encoded.end(), resize.replay.begin(), resize.replay.end());
  AppendKittyImageAliases(&encoded, resize.kitty_image_aliases);
  if (encoded.size() > kTerminalHostMaxFramePayload) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostResize(std::string_view payload,
                                                   TerminalHostResize* resize) {
  if (!resize) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() > kTerminalHostMaxFramePayload) {
    return TerminalHostProtocolError::kPayloadTooLarge;
  }
  PayloadReader reader(payload);
  TerminalHostResize decoded;
  std::string_view replay;
  if (!reader.U16(&decoded.cols) || !reader.U16(&decoded.rows) ||
      !reader.Bytes(kTerminalHostMaxSnapshotReplay, &replay)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  decoded.replay.assign(replay.begin(), replay.end());
  if (ReadKittyImageAliases(&reader, &decoded.kitty_image_aliases) !=
          TerminalHostProtocolError::kNone ||
      !reader.finished()) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  decoded.cols = std::max<uint16_t>(decoded.cols, 1);
  decoded.rows = std::max<uint16_t>(decoded.rows, 1);
  *resize = std::move(decoded);
  return TerminalHostProtocolError::kNone;
}

bool TerminalHostResizeAck::operator==(
    const TerminalHostResizeAck& other) const {
  return cols == other.cols && rows == other.rows &&
         result_flags == other.result_flags;
}

TerminalHostProtocolError EncodeTerminalHostResizeAck(
    const TerminalHostResizeAck& ack,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if ((ack.result_flags & ~kTerminalHostResizeAckCanonicalChanged) != 0) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(8);
  AppendU16(&encoded, std::max<uint16_t>(ack.cols, 1));
  AppendU16(&encoded, std::max<uint16_t>(ack.rows, 1));
  AppendU32(&encoded, ack.result_flags);
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostResizeAck(
    std::string_view payload,
    TerminalHostResizeAck* ack) {
  if (!ack) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != 8) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  TerminalHostResizeAck decoded;
  decoded.cols = std::max<uint16_t>(ReadU16(payload, 0), 1);
  decoded.rows = std::max<uint16_t>(ReadU16(payload, 2), 1);
  decoded.result_flags = ReadU32(payload, 4);
  if ((decoded.result_flags & ~kTerminalHostResizeAckCanonicalChanged) != 0) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  *ack = decoded;
  return TerminalHostProtocolError::kNone;
}

bool TerminalHostRgb::operator==(const TerminalHostRgb& other) const {
  return red == other.red && green == other.green && blue == other.blue;
}

bool TerminalHostPaletteEntry::operator==(
    const TerminalHostPaletteEntry& other) const {
  return index == other.index && color == other.color;
}

bool TerminalHostCursorVisual::operator==(
    const TerminalHostCursorVisual& other) const {
  return style == other.style && blinking == other.blinking;
}

TerminalHostColors::TerminalHostColors() = default;
TerminalHostColors::TerminalHostColors(const TerminalHostColors&) = default;
TerminalHostColors& TerminalHostColors::operator=(const TerminalHostColors&) =
    default;
TerminalHostColors::TerminalHostColors(TerminalHostColors&&) = default;
TerminalHostColors& TerminalHostColors::operator=(TerminalHostColors&&) =
    default;
TerminalHostColors::~TerminalHostColors() = default;

bool TerminalHostColors::operator==(const TerminalHostColors& other) const {
  return foreground == other.foreground && background == other.background &&
         cursor == other.cursor && cursor_visual == other.cursor_visual &&
         palette == other.palette;
}

TerminalHostProtocolError EncodeTerminalHostColors(
    const TerminalHostColors& colors,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (colors.palette.size() > kTerminalHostPaletteSize) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  std::array<bool, kTerminalHostPaletteSize> seen{};
  for (const TerminalHostPaletteEntry& entry : colors.palette) {
    if (seen[entry.index]) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
    seen[entry.index] = true;
  }
  if (!colors.cursor_visual ||
      colors.cursor_visual->style < TerminalHostCursorStyle::kBlock ||
      colors.cursor_visual->style > TerminalHostCursorStyle::kBar) {
    return TerminalHostProtocolError::kMalformedPayload;
  }

  uint16_t flags = 0;
  flags |= colors.foreground.has_value() ? 1u : 0u;
  flags |= colors.background.has_value() ? 2u : 0u;
  flags |= colors.cursor.has_value() ? 4u : 0u;
  flags |= colors.cursor_visual.has_value() ? 8u : 0u;
  std::vector<uint8_t> encoded;
  encoded.reserve(8 +
                  (colors.foreground.has_value() +
                   colors.background.has_value() + colors.cursor.has_value()) *
                      3 +
                  (colors.cursor_visual.has_value() ? 2 : 0) +
                  colors.palette.size() * 4);
  AppendU16(&encoded, kTerminalHostColorsVersion);
  AppendU16(&encoded, flags);
  AppendU16(&encoded, static_cast<uint16_t>(colors.palette.size()));
  AppendU16(&encoded, 0);
  const auto append_rgb = [&encoded](const TerminalHostRgb& color) {
    encoded.push_back(color.red);
    encoded.push_back(color.green);
    encoded.push_back(color.blue);
  };
  if (colors.foreground) {
    append_rgb(*colors.foreground);
  }
  if (colors.background) {
    append_rgb(*colors.background);
  }
  if (colors.cursor) {
    append_rgb(*colors.cursor);
  }
  if (colors.cursor_visual) {
    encoded.push_back(static_cast<uint8_t>(colors.cursor_visual->style));
    encoded.push_back(colors.cursor_visual->blinking ? 1 : 0);
  }
  for (const TerminalHostPaletteEntry& entry : colors.palette) {
    encoded.push_back(entry.index);
    append_rgb(entry.color);
  }
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostColors(std::string_view payload,
                                                   TerminalHostColors* colors) {
  if (!colors) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() < 8 || payload.size() > kTerminalHostMaxColorsPayload) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  const uint16_t version = ReadU16(payload, 0);
  const uint16_t flags = ReadU16(payload, 2);
  const size_t palette_count = ReadU16(payload, 4);
  const uint16_t reserved = ReadU16(payload, 6);
  const bool is_v1 = version == kTerminalHostColorsVersionV1;
  const bool is_v2 = version == kTerminalHostColorsVersion;
  const uint16_t known_flags = is_v1 ? 0x7u : 0xfu;
  if ((!is_v1 && !is_v2) || (flags & ~known_flags) != 0 ||
      palette_count > kTerminalHostPaletteSize || reserved != 0) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  size_t flagged_count = 0;
  for (uint16_t mask = 1; mask <= 4; mask <<= 1) {
    flagged_count += (flags & mask) != 0;
  }
  const bool has_cursor_visual = (flags & 8u) != 0;
  if (is_v2 && !has_cursor_visual) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  const size_t expected_length = 8 + flagged_count * 3 +
                                 (has_cursor_visual ? 2 : 0) +
                                 palette_count * 4;
  if (payload.size() != expected_length) {
    return TerminalHostProtocolError::kMalformedPayload;
  }

  TerminalHostColors decoded;
  size_t offset = 8;
  const auto take_rgb = [&payload, &offset]() {
    TerminalHostRgb color{static_cast<uint8_t>(payload[offset]),
                          static_cast<uint8_t>(payload[offset + 1]),
                          static_cast<uint8_t>(payload[offset + 2])};
    offset += 3;
    return color;
  };
  if ((flags & 1u) != 0) {
    decoded.foreground = take_rgb();
  }
  if ((flags & 2u) != 0) {
    decoded.background = take_rgb();
  }
  if ((flags & 4u) != 0) {
    decoded.cursor = take_rgb();
  }
  if (has_cursor_visual) {
    const uint8_t raw_style = static_cast<uint8_t>(payload[offset++]);
    const uint8_t raw_blinking = static_cast<uint8_t>(payload[offset++]);
    if (raw_style < static_cast<uint8_t>(TerminalHostCursorStyle::kBlock) ||
        raw_style > static_cast<uint8_t>(TerminalHostCursorStyle::kBar) ||
        raw_blinking > 1) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
    decoded.cursor_visual = TerminalHostCursorVisual{
        static_cast<TerminalHostCursorStyle>(raw_style), raw_blinking != 0};
  }
  std::array<bool, kTerminalHostPaletteSize> seen{};
  decoded.palette.reserve(palette_count);
  for (size_t index = 0; index < palette_count; ++index) {
    const uint8_t palette_index = static_cast<uint8_t>(payload[offset++]);
    if (seen[palette_index]) {
      return TerminalHostProtocolError::kMalformedPayload;
    }
    seen[palette_index] = true;
    decoded.palette.push_back({palette_index, take_rgb()});
  }
  *colors = std::move(decoded);
  return TerminalHostProtocolError::kNone;
}

void AppendTerminalHostColorMetadata(const TerminalHostColors& colors,
                                     std::vector<uint8_t>* bytes) {
  if (!bytes) {
    return;
  }
  constexpr std::array<char, 16> kHex = {
      '0', '1', '2', '3', '4', '5', '6', '7',
      '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
  const auto append_text = [bytes](std::string_view text) {
    bytes->insert(bytes->end(), text.begin(), text.end());
  };
  const auto append_rgb_value = [bytes, &append_text, &kHex](
                                    const TerminalHostRgb& color) {
    append_text("rgb:");
    const auto component = [bytes, &kHex](uint8_t value) {
      bytes->push_back(kHex[value >> 4]);
      bytes->push_back(kHex[value & 0x0f]);
    };
    component(color.red);
    bytes->push_back('/');
    component(color.green);
    bytes->push_back('/');
    component(color.blue);
  };
  const auto append_default = [bytes, &append_text, &append_rgb_value](
                                  std::string_view set_code,
                                  std::string_view reset_code,
                                  const std::optional<TerminalHostRgb>& color) {
    append_text("\x1b]");
    append_text(color ? set_code : reset_code);
    if (color) {
      bytes->push_back(';');
      append_rgb_value(*color);
    }
    bytes->push_back('\a');
  };

  append_text("\x1b]104\a");
  for (const TerminalHostPaletteEntry& entry : colors.palette) {
    append_text("\x1b]4;");
    append_text(std::to_string(entry.index));
    bytes->push_back(';');
    append_rgb_value(entry.color);
    bytes->push_back('\a');
  }
  append_default("10", "110", colors.foreground);
  append_default("11", "111", colors.background);
  append_default("12", "112", colors.cursor);
  if (colors.cursor_visual) {
    append_text("\x1b[0 q");
    const uint8_t shape = static_cast<uint8_t>(colors.cursor_visual->style);
    const uint8_t decscusr = static_cast<uint8_t>(
        shape * 2 - (colors.cursor_visual->blinking ? 1 : 0));
    append_text("\x1b[");
    bytes->push_back(static_cast<uint8_t>('0' + decscusr));
    append_text(" q");
  }
}

TerminalHostProtocolError DecodeTerminalHostUtf8(std::string_view payload,
                                                 std::string* text) {
  if (!text) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() > kTerminalHostMaxString || !IsValidUtf8(payload)) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  text->assign(payload);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError EncodeTerminalHostViewerSize(
    uint16_t cols,
    uint16_t rows,
    std::vector<uint8_t>* payload) {
  if (!payload) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  std::vector<uint8_t> encoded;
  encoded.reserve(4);
  AppendU16(&encoded, std::max<uint16_t>(cols, 1));
  AppendU16(&encoded, std::max<uint16_t>(rows, 1));
  *payload = std::move(encoded);
  return TerminalHostProtocolError::kNone;
}

TerminalHostProtocolError DecodeTerminalHostViewerSize(std::string_view payload,
                                                       uint16_t* cols,
                                                       uint16_t* rows) {
  if (!cols || !rows) {
    return TerminalHostProtocolError::kInvalidArgument;
  }
  if (payload.size() != 4) {
    return TerminalHostProtocolError::kMalformedPayload;
  }
  *cols = std::max<uint16_t>(ReadU16(payload, 0), 1);
  *rows = std::max<uint16_t>(ReadU16(payload, 2), 1);
  return TerminalHostProtocolError::kNone;
}

}  // namespace cmux
