// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

// Host-compilable tests for the cmux terminal-host binary wire protocol. No
// Chromium or gtest dependencies.

#include "chrome/services/cmux_terminal_renderer/public/cpp/cmux_terminal_host_protocol.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

int checks = 0;
int failures = 0;

constexpr uint16_t kRustTerminalHostProtocolVersion = 2;
constexpr size_t kRustTerminalHostMaxReplay = 15'692'630;
constexpr size_t kRustTerminalHostMaxKittyImageAliases = 4'096;

void Check(bool condition, const char* message) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
}

std::string_view Bytes(const std::vector<uint8_t>& bytes) {
  return std::string_view(reinterpret_cast<const char*>(bytes.data()),
                          bytes.size());
}

template <size_t N>
std::array<uint8_t, N> Filled(uint8_t value) {
  std::array<uint8_t, N> result;
  result.fill(value);
  return result;
}

template <typename Payload, typename = void>
struct HasKittyImageAliases : std::false_type {};

template <typename Payload>
struct HasKittyImageAliases<
    Payload,
    std::void_t<
        decltype(std::declval<Payload&>().kitty_image_aliases)>>
    : std::true_type {};

template <typename Payload>
using PayloadEncoder = cmux::TerminalHostProtocolError (*)(
    const Payload&,
    std::vector<uint8_t>*);

template <typename Payload>
using PayloadDecoder = cmux::TerminalHostProtocolError (*)(
    std::string_view,
    Payload*);

template <typename Payload>
bool KittyAliasesRoundTrip(PayloadEncoder<Payload> encode,
                           PayloadDecoder<Payload> decode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}, Alias{42, 78}};
    std::vector<uint8_t> payload;
    Payload decoded;
    if (encode(value, &payload) != cmux::TerminalHostProtocolError::kNone ||
        decode(Bytes(payload), &decoded) !=
            cmux::TerminalHostProtocolError::kNone ||
        !(decoded == value)) {
      return false;
    }
    constexpr std::array<uint8_t, 18> kAliasSuffix = {
        2, 0, 41, 0, 0, 0, 77, 0, 0, 0, 42, 0, 0, 0, 78, 0, 0, 0,
    };
    return payload.size() >= kAliasSuffix.size() &&
           std::equal(kAliasSuffix.begin(), kAliasSuffix.end(),
                      payload.end() - kAliasSuffix.size());
  }
}

enum class InvalidKittyAlias {
  kZeroId,
  kZeroNumber,
  kDuplicateId,
  kDuplicateNumber,
};

template <typename Payload>
bool KittyAliasEncoderRejects(PayloadEncoder<Payload> encode,
                              InvalidKittyAlias invalid) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    switch (invalid) {
      case InvalidKittyAlias::kZeroId:
        value.kitty_image_aliases = {Alias{0, 77}};
        break;
      case InvalidKittyAlias::kZeroNumber:
        value.kitty_image_aliases = {Alias{41, 0}};
        break;
      case InvalidKittyAlias::kDuplicateId:
        value.kitty_image_aliases = {Alias{41, 77}, Alias{41, 78}};
        break;
      case InvalidKittyAlias::kDuplicateNumber:
        value.kitty_image_aliases = {Alias{41, 77}, Alias{42, 77}};
        break;
    }
    std::vector<uint8_t> untouched = {0xa5};
    return encode(value, &untouched) ==
               cmux::TerminalHostProtocolError::kMalformedPayload &&
           untouched == std::vector<uint8_t>({0xa5});
  }
}

template <typename Payload>
bool KittyAliasDecoderRejects(PayloadEncoder<Payload> encode,
                              PayloadDecoder<Payload> decode,
                              InvalidKittyAlias invalid) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}, Alias{42, 78}};
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != cmux::TerminalHostProtocolError::kNone ||
        payload.size() < 18) {
      return false;
    }
    const size_t aliases = payload.size() - 18;
    switch (invalid) {
      case InvalidKittyAlias::kZeroId:
        std::fill(payload.begin() + aliases + 2,
                  payload.begin() + aliases + 6, 0);
        break;
      case InvalidKittyAlias::kZeroNumber:
        std::fill(payload.begin() + aliases + 6,
                  payload.begin() + aliases + 10, 0);
        break;
      case InvalidKittyAlias::kDuplicateId:
        std::copy(payload.begin() + aliases + 2,
                  payload.begin() + aliases + 6,
                  payload.begin() + aliases + 10);
        break;
      case InvalidKittyAlias::kDuplicateNumber:
        std::copy(payload.begin() + aliases + 6,
                  payload.begin() + aliases + 10,
                  payload.begin() + aliases + 14);
        break;
    }
    Payload decoded;
    return decode(Bytes(payload), &decoded) ==
           cmux::TerminalHostProtocolError::kMalformedPayload;
  }
}

template <typename Payload>
bool KittyAliasDecoderRejectsBadFraming(PayloadEncoder<Payload> encode,
                                        PayloadDecoder<Payload> decode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}};
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != cmux::TerminalHostProtocolError::kNone) {
      return false;
    }
    Payload decoded;
    std::vector<uint8_t> truncated = payload;
    truncated.pop_back();
    std::vector<uint8_t> trailing = payload;
    trailing.push_back(0);
    return decode(Bytes(truncated), &decoded) ==
               cmux::TerminalHostProtocolError::kMalformedPayload &&
           decode(Bytes(trailing), &decoded) ==
               cmux::TerminalHostProtocolError::kMalformedPayload;
  }
}

template <typename Payload>
bool KittyAliasCountIsBounded(PayloadEncoder<Payload> encode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases.reserve(
        kRustTerminalHostMaxKittyImageAliases + 1);
    for (size_t index = 0;
         index < kRustTerminalHostMaxKittyImageAliases; ++index) {
      value.kitty_image_aliases.push_back(
          Alias{static_cast<uint32_t>(index + 1),
                static_cast<uint32_t>(index + 10'001)});
    }
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != cmux::TerminalHostProtocolError::kNone) {
      return false;
    }
    value.kitty_image_aliases.push_back(
        Alias{static_cast<uint32_t>(
                  kRustTerminalHostMaxKittyImageAliases + 1),
              static_cast<uint32_t>(
                  kRustTerminalHostMaxKittyImageAliases + 10'001)});
    payload = {0xa5};
    return encode(value, &payload) ==
               cmux::TerminalHostProtocolError::kPayloadTooLarge &&
           payload == std::vector<uint8_t>({0xa5});
  }
}

cmux::TerminalHostFrame SampleFrame() {
  cmux::TerminalHostFrame frame;
  frame.kind = cmux::TerminalHostMessageKind::kOutput;
  frame.flags = 0x11223344;
  frame.request_id = 0x0102030405060708ULL;
  frame.sequence = 0x1112131415161718ULL;
  frame.payload = {0xaa, 0xbb, 0xcc};
  return frame;
}

void TestFrameGoldenAndKinds() {
  using Error = cmux::TerminalHostProtocolError;
  Check(cmux::kTerminalHostProtocolVersion ==
            kRustTerminalHostProtocolVersion,
        "terminal-host default protocol version matches Rust v2");
  Check(cmux::kTerminalHostFlagColorsFollow == 1u,
        "COLORS_FOLLOW is exactly header flag bit zero");
  Check(cmux::kTerminalHostFlagViewerSizeAcks == 2u,
        "VIEWER_SIZE_ACKS is exactly header flag bit one");
  std::vector<uint8_t> encoded;
  Check(cmux::EncodeTerminalHostFrame(SampleFrame(), &encoded) == Error::kNone,
        "sample frame encodes");
  Check(encoded == std::vector<uint8_t>({
                       'C',  'M',  'T',  'H',  0x02, 0x00, 0x06, 0x00, 0x44,
                       0x33, 0x22, 0x11, 0x03, 0x00, 0x00, 0x00, 0x08, 0x07,
                       0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x18, 0x17, 0x16,
                       0x15, 0x14, 0x13, 0x12, 0x11, 0xaa, 0xbb, 0xcc,
                   }),
        "frame is the Rust golden byte sequence");

  cmux::TerminalHostFrameDecoder decoder;
  std::vector<cmux::TerminalHostFrame> frames;
  Check(decoder.Push(Bytes(encoded), &frames) == Error::kNone,
        "golden frame decodes");
  Check(frames == std::vector<cmux::TerminalHostFrame>({SampleFrame()}),
        "golden frame fields round trip");
  Check(decoder.Finish() == Error::kNone, "complete decoder finishes cleanly");

  cmux::TerminalHostFrameHeader header;
  Check(cmux::DecodeTerminalHostFrameHeader(
            Bytes(encoded).substr(0, cmux::kTerminalHostHeaderLength), 3,
            &header) == Error::kNone &&
            header.version == 2 &&
            header.kind == cmux::TerminalHostMessageKind::kOutput &&
            header.flags == 0x11223344 && header.payload_length == 3 &&
            header.request_id == 0x0102030405060708ULL &&
            header.sequence == 0x1112131415161718ULL,
        "header-only decoder exposes every fixed little-endian field");
  Check(cmux::DecodeTerminalHostFrameHeader(
            Bytes(encoded).substr(0, cmux::kTerminalHostHeaderLength), 2,
            &header) == Error::kPayloadTooLarge,
        "header-only decoder enforces caller payload bound");

  const std::vector<std::pair<cmux::TerminalHostMessageKind, uint16_t>> kinds =
      {
          {cmux::TerminalHostMessageKind::kBootstrap, 1},
          {cmux::TerminalHostMessageKind::kReady, 2},
          {cmux::TerminalHostMessageKind::kClientHello, 3},
          {cmux::TerminalHostMessageKind::kHostHello, 4},
          {cmux::TerminalHostMessageKind::kSnapshot, 5},
          {cmux::TerminalHostMessageKind::kOutput, 6},
          {cmux::TerminalHostMessageKind::kResized, 7},
          {cmux::TerminalHostMessageKind::kColors, 8},
          {cmux::TerminalHostMessageKind::kTitle, 9},
          {cmux::TerminalHostMessageKind::kPwd, 10},
          {cmux::TerminalHostMessageKind::kBell, 11},
          {cmux::TerminalHostMessageKind::kExit, 12},
          {cmux::TerminalHostMessageKind::kResyncRequired, 13},
          {cmux::TerminalHostMessageKind::kLaunch, 14},
          {cmux::TerminalHostMessageKind::kCapability, 15},
          {cmux::TerminalHostMessageKind::kResizeAck, 16},
          {cmux::TerminalHostMessageKind::kInput, 100},
          {cmux::TerminalHostMessageKind::kPaste, 101},
          {cmux::TerminalHostMessageKind::kViewerSize, 102},
          {cmux::TerminalHostMessageKind::kReleaseViewer, 103},
          {cmux::TerminalHostMessageKind::kTerminate, 104},
          {cmux::TerminalHostMessageKind::kMintCapability, 105},
      };
  std::vector<uint8_t> stream;
  for (const auto& [kind, wire_number] : kinds) {
    Check(static_cast<uint16_t>(kind) == wire_number,
          "message kind has the exact Rust wire number");
    cmux::TerminalHostFrame frame;
    frame.kind = kind;
    std::vector<uint8_t> one;
    Check(cmux::EncodeTerminalHostFrame(frame, &one) == Error::kNone,
          "known message kind encodes");
    stream.insert(stream.end(), one.begin(), one.end());
  }
  frames.clear();
  cmux::TerminalHostFrameDecoder all_kinds_decoder;
  Check(all_kinds_decoder.Push(Bytes(stream), &frames) == Error::kNone,
        "all known coalesced message kinds decode");
  Check(frames.size() == kinds.size(), "every message kind produced a frame");
  for (size_t index = 0; index < std::min(frames.size(), kinds.size());
       ++index) {
    Check(frames[index].kind == kinds[index].first,
          "message kind number decodes exactly");
  }
}

std::string Hex(const std::vector<uint8_t>& bytes) {
  constexpr char kDigits[] = "0123456789abcdef";
  std::string result;
  result.resize(bytes.size() * 2);
  for (size_t index = 0; index < bytes.size(); ++index) {
    result[index * 2] = kDigits[bytes[index] >> 4];
    result[index * 2 + 1] = kDigits[bytes[index] & 0x0f];
  }
  return result;
}

void TestRendererGrantValidation() {
  using Error = cmux::TerminalHostRendererGrantError;
  using Rights = cmux::TerminalHostCapabilityRights;

  cmux::TerminalHostId terminal = Filled<16>(0x11);
  terminal[6] = 0x41;
  terminal[8] = 0x81;
  cmux::TerminalHostIncarnation incarnation = Filled<16>(0x22);
  incarnation[6] = 0x42;
  incarnation[8] = 0x82;
  const std::string terminal_hex = cmux::EncodeTerminalHostId(terminal);
  const std::string incarnation_hex = cmux::EncodeTerminalHostId(incarnation);
  const std::string token_hex = Hex(std::vector<uint8_t>(32, 0xa5));
  const std::string endpoint = "/tmp/cmux-th-501/" + terminal_hex + ".sock";

  cmux::TerminalHostId decoded_terminal{};
  Check(cmux::DecodeTerminalHostUuidV4(terminal_hex, &decoded_terminal) &&
            decoded_terminal == terminal &&
            cmux::IsValidTerminalHostUuidV4(decoded_terminal),
        "stable terminal UUID decodes for create/resolve responses");
  decoded_terminal = Filled<16>(0xee);
  Check(!cmux::DecodeTerminalHostUuidV4(
            std::string("A") + terminal_hex.substr(1), &decoded_terminal) &&
            decoded_terminal == Filled<16>(0xee),
        "stable UUID decoder rejects noncanonical text atomically");
  Check(!cmux::DecodeTerminalHostUuidV4(terminal_hex, nullptr),
        "stable UUID decoder requires an output destination");

  cmux::TerminalHostRendererGrant grant;
  Check(cmux::ValidateTerminalHostRendererGrant(
            endpoint, terminal_hex, incarnation_hex, token_hex,
            static_cast<uint32_t>(Rights::kRenderer), 30000, 30000,
            &grant) == Error::kNone,
        "canonical renderer grant validates");
  Check(grant.endpoint == endpoint && grant.terminal_id == terminal &&
            grant.incarnation == incarnation &&
            grant.token == Filled<32>(0xa5) &&
            grant.rights == Rights::kRenderer && grant.ttl_ms == 30000,
        "validated renderer grant contains typed binary identities and token");
  Check(std::string(cmux::TerminalHostRendererGrantErrorMessage(Error::kNone))
            .empty(),
        "successful grant validation has no error text");

  const auto Validate = [&](std::string_view candidate_endpoint,
                            std::string_view candidate_terminal,
                            std::string_view candidate_incarnation,
                            std::string_view candidate_token,
                            uint64_t candidate_rights, uint64_t candidate_ttl,
                            uint64_t expected_ttl) {
    cmux::TerminalHostRendererGrant output;
    output.endpoint = "untouched";
    const Error error = cmux::ValidateTerminalHostRendererGrant(
        candidate_endpoint, candidate_terminal, candidate_incarnation,
        candidate_token, candidate_rights, candidate_ttl, expected_ttl,
        &output);
    Check(error == Error::kNone || output.endpoint == "untouched",
          "invalid grant leaves typed destination untouched");
    return error;
  };

  for (const std::string& invalid :
       {std::string(), std::string("relative.sock"),
        std::string("/private/tmp/cmux-th-501/") + terminal_hex + ".sock",
        std::string("/tmp/cmux-th-/") + terminal_hex + ".sock",
        std::string("/tmp/cmux-th-user/") + terminal_hex + ".sock",
        std::string("/tmp/cmux-th-501/nested/") + terminal_hex + ".sock",
        std::string("/tmp/cmux-th-501/") + terminal_hex,
        std::string("/tmp/cmux-th-501/") + incarnation_hex + ".sock"}) {
    Check(Validate(invalid, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                   30000) == Error::kInvalidEndpoint,
          "noncanonical renderer endpoint is rejected");
  }
  std::string nul_endpoint = endpoint;
  nul_endpoint.insert(5, 1, '\0');
  Check(Validate(std::string_view(nul_endpoint.data(), nul_endpoint.size()),
                 terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidEndpoint,
        "renderer endpoint rejects embedded NUL");
  const std::string long_endpoint =
      "/tmp/cmux-th-501/" + std::string(90, 'a') + ".sock";
  Check(Validate(long_endpoint, terminal_hex, incarnation_hex, token_hex, 7,
                 30000, 30000) == Error::kInvalidEndpoint,
        "renderer endpoint rejects paths beyond macOS sockaddr_un capacity");

  std::string bad_terminal = terminal_hex.substr(1);
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID has exact width");
  bad_terminal = terminal_hex;
  bad_terminal[0] = 'A';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID requires canonical lowercase hex");
  bad_terminal = terminal_hex;
  bad_terminal[12] = '3';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal identity must be UUIDv4");
  bad_terminal = terminal_hex;
  bad_terminal[16] = '4';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID requires the RFC variant");

  std::string bad_incarnation = incarnation_hex;
  bad_incarnation[0] = 'z';
  Check(Validate(endpoint, terminal_hex, bad_incarnation, token_hex, 7, 30000,
                 30000) == Error::kInvalidIncarnation,
        "renderer incarnation rejects non-hex text");
  bad_incarnation = incarnation_hex;
  bad_incarnation[12] = '5';
  Check(Validate(endpoint, terminal_hex, bad_incarnation, token_hex, 7, 30000,
                 30000) == Error::kInvalidIncarnation,
        "renderer incarnation must be UUIDv4");

  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex.substr(2),
                 7, 30000, 30000) == Error::kInvalidToken,
        "renderer capability token has exact 32-byte width");
  std::string bad_token = token_hex;
  bad_token[0] = 'A';
  Check(Validate(endpoint, terminal_hex, incarnation_hex, bad_token, 7, 30000,
                 30000) == Error::kInvalidToken,
        "renderer capability token requires canonical lowercase hex");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, std::string(64, '0'),
                 7, 30000, 30000) == Error::kInvalidToken,
        "renderer capability token cannot be all zero");

  for (const uint64_t invalid_rights :
       {0ULL, 1ULL, 3ULL, 15ULL, 0x1'0000'0007ULL}) {
    Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex,
                   invalid_rights, 30000, 30000) == Error::kInvalidRights,
          "renderer grant requires the exact read/input/resize rights set");
  }
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 0,
                 30000) == Error::kInvalidTtl,
        "renderer grant rejects zero response TTL");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 60001,
                 60001) == Error::kInvalidTtl,
        "renderer grant rejects response TTL above 60 seconds");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 0) == Error::kInvalidTtl,
        "renderer grant rejects invalid requested TTL");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 29999) == Error::kInvalidTtl,
        "renderer grant TTL must echo the exact request");
  Check(cmux::ValidateTerminalHostRendererGrant(
            endpoint, terminal_hex, incarnation_hex, token_hex, 7, 30000, 30000,
            nullptr) == Error::kInvalidEndpoint,
        "renderer grant requires an output destination");
}

void TestFragmentationAndCoalescing() {
  using Error = cmux::TerminalHostProtocolError;
  cmux::TerminalHostFrame second;
  second.kind = cmux::TerminalHostMessageKind::kViewerSize;
  second.request_id = 9;
  second.payload = {80, 0, 24, 0};

  std::vector<uint8_t> stream;
  std::vector<uint8_t> encoded_second;
  Check(cmux::EncodeTerminalHostFrame(SampleFrame(), &stream) == Error::kNone,
        "first fragmented frame encodes");
  Check(cmux::EncodeTerminalHostFrame(second, &encoded_second) == Error::kNone,
        "second fragmented frame encodes");
  stream.insert(stream.end(), encoded_second.begin(), encoded_second.end());

  cmux::TerminalHostFrameDecoder fragmented;
  std::vector<cmux::TerminalHostFrame> frames;
  for (uint8_t byte : stream) {
    const char one = static_cast<char>(byte);
    Check(fragmented.Push(std::string_view(&one, 1), &frames) == Error::kNone,
          "one-byte fragment is accepted");
  }
  Check(frames == std::vector<cmux::TerminalHostFrame>({SampleFrame(), second}),
        "one-byte fragments preserve frame boundaries");
  Check(fragmented.Finish() == Error::kNone,
        "fragmented decoder drains completely");

  frames.clear();
  cmux::TerminalHostFrameDecoder coalesced;
  Check(coalesced.Push(Bytes(stream), &frames) == Error::kNone,
        "coalesced frames decode in one push");
  Check(frames == std::vector<cmux::TerminalHostFrame>({SampleFrame(), second}),
        "coalesced frames preserve order");
}

void TestMalformedFrames() {
  using Error = cmux::TerminalHostProtocolError;
  std::vector<uint8_t> encoded;
  Check(cmux::EncodeTerminalHostFrame(SampleFrame(), &encoded) == Error::kNone,
        "malformed-frame fixture encodes");

  auto DecodeError = [](const std::vector<uint8_t>& bytes) {
    cmux::TerminalHostFrameDecoder decoder;
    std::vector<cmux::TerminalHostFrame> frames;
    return decoder.Push(Bytes(bytes), &frames);
  };

  std::vector<uint8_t> bad = encoded;
  bad[0] = 'X';
  Check(DecodeError(bad) == Error::kInvalidMagic, "bad magic is rejected");
  bad = encoded;
  bad[4] = 0;
  bad[5] = 0;
  Check(DecodeError(bad) == Error::kInvalidVersion,
        "zero header version is rejected");
  bad = encoded;
  bad[4] = 2;
  cmux::TerminalHostFrameDecoder future_version;
  std::vector<cmux::TerminalHostFrame> frames;
  Check(future_version.Push(Bytes(bad), &frames) == Error::kNone &&
            frames.size() == 1 && frames[0].version == 2,
        "nonzero frame versions remain parseable before hello negotiation");
  bad = encoded;
  bad[6] = 0xe7;
  bad[7] = 0x03;
  Check(DecodeError(bad) == Error::kUnknownMessageKind,
        "unknown message kind is rejected");

  bad = encoded;
  bad.resize(cmux::kTerminalHostHeaderLength);
  bad[12] = 65;
  bad[13] = bad[14] = bad[15] = 0;
  cmux::TerminalHostFrameDecoder bounded(64);
  Check(bounded.Push(Bytes(bad), &frames) == Error::kPayloadTooLarge,
        "advertised payload over the caller cap is rejected at the header");
  Check(bounded.buffered_bytes() == cmux::kTerminalHostHeaderLength,
        "oversize header does not allocate or retain advertised payload");
  Check(bounded.failed(), "malformed stream poisons decoder");
  Check(bounded.Push({}, &frames) == Error::kDecoderFailed,
        "poisoned decoder cannot resume at an attacker-selected offset");
  Check(bounded.Finish() == Error::kDecoderFailed,
        "poisoned decoder cannot finish successfully");

  cmux::TerminalHostFrameDecoder short_header;
  Check(short_header.Push(Bytes(encoded).substr(0, 8), &frames) == Error::kNone,
        "partial header buffers");
  Check(short_header.buffered_bytes() == 8,
        "partial header byte count is exact");
  Check(short_header.Finish() == Error::kTruncated,
        "partial header is truncated at EOF");

  cmux::TerminalHostFrameDecoder short_payload;
  Check(short_payload.Push(
            Bytes(encoded).substr(0, cmux::kTerminalHostHeaderLength + 1),
            &frames) == Error::kNone,
        "partial payload buffers");
  Check(short_payload.Finish() == Error::kTruncated,
        "partial payload is truncated at EOF");

  cmux::TerminalHostFrame too_large;
  too_large.kind = cmux::TerminalHostMessageKind::kInput;
  too_large.payload.resize(cmux::kTerminalHostMaxFramePayload + 1);
  std::vector<uint8_t> untouched = {7, 8, 9};
  Check(cmux::EncodeTerminalHostFrame(too_large, &untouched) ==
            Error::kPayloadTooLarge,
        "encoder enforces the global frame cap");
  Check(untouched == std::vector<uint8_t>({7, 8, 9}),
        "failed frame encode leaves destination untouched");
  cmux::TerminalHostFrame unknown;
  unknown.kind = static_cast<cmux::TerminalHostMessageKind>(999);
  Check(cmux::EncodeTerminalHostFrame(unknown, &untouched) ==
            Error::kUnknownMessageKind,
        "encoder rejects forged enum values");
}

void TestHelloPayloads() {
  using Error = cmux::TerminalHostProtocolError;
  using Rights = cmux::TerminalHostCapabilityRights;

  cmux::TerminalHostClientHello client;
  client.min_version = 1;
  client.max_version = 0x0203;
  client.role = cmux::TerminalHostClientRole::kRenderer;
  client.requested_rights = Rights::kRead | Rights::kInput;
  client.terminal_id = Filled<16>(0x44);
  client.token = Filled<32>(0xa5);
  std::vector<uint8_t> payload;
  Check(cmux::EncodeTerminalHostClientHello(client, &payload) == Error::kNone,
        "client hello encodes");
  Check(payload.size() == 60, "client hello has the Rust fixed width");
  Check(std::equal(
            payload.begin(), payload.begin() + 12,
            std::vector<uint8_t>({1, 0, 3, 2, 2, 0, 0, 0, 3, 0, 0, 0}).begin()),
        "client hello prefix and reserved bytes are little-endian");
  cmux::TerminalHostClientHello decoded_client;
  Check(cmux::DecodeTerminalHostClientHello(Bytes(payload), &decoded_client) ==
                Error::kNone &&
            decoded_client == client,
        "client hello round trips exactly");

  std::vector<uint8_t> malformed = payload;
  malformed[5] = 1;
  Check(cmux::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects nonzero reserved bytes");
  malformed = payload;
  malformed[4] = 99;
  Check(cmux::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects unknown roles");
  malformed = payload;
  malformed[11] = 0x80;
  Check(cmux::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects unknown capability bits");
  Check(cmux::DecodeTerminalHostClientHello(Bytes(payload).substr(1),
                                            &decoded_client) ==
            Error::kMalformedPayload,
        "client hello rejects wrong fixed width");

  cmux::TerminalHostHostHello host;
  host.selected_version = 2;
  host.granted_rights = Rights::kRead;
  host.terminal_id = client.terminal_id;
  host.incarnation = Filled<16>(7);
  Check(cmux::EncodeTerminalHostHostHello(host, &payload) == Error::kNone,
        "host hello encodes");
  Check(payload.size() == 40 && payload[0] == 2 && payload[1] == 0 &&
            payload[2] == 0 && payload[3] == 0 && payload[4] == 1,
        "host hello has fixed width and little-endian reserved prefix");
  cmux::TerminalHostHostHello decoded_host;
  Check(cmux::DecodeTerminalHostHostHello(Bytes(payload), &decoded_host) ==
                Error::kNone &&
            decoded_host == host,
        "host hello round trips exactly");
  malformed = payload;
  malformed[2] = 1;
  Check(cmux::DecodeTerminalHostHostHello(Bytes(malformed), &decoded_host) ==
            Error::kMalformedPayload,
        "host hello rejects nonzero reserved bytes");
  malformed = payload;
  malformed[7] = 0x40;
  Check(cmux::DecodeTerminalHostHostHello(Bytes(malformed), &decoded_host) ==
            Error::kMalformedPayload,
        "host hello rejects unknown capability bits");

  Check(cmux::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kRead, cmux::TerminalHostClientRole::kDaemonMirror),
        "daemon mirror may read");
  Check(!cmux::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kInput, cmux::TerminalHostClientRole::kDaemonMirror),
        "daemon mirror may not write input");
  Check(cmux::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kRead | Rights::kInput | Rights::kResize,
            cmux::TerminalHostClientRole::kRenderer),
        "renderer may read, input, and resize");
  Check(!cmux::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kTerminate, cmux::TerminalHostClientRole::kRenderer),
        "renderer may not terminate");
  Check(cmux::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kAdmin, cmux::TerminalHostClientRole::kAdmin),
        "admin role may request every known right");
}

void TestSnapshotPayload() {
  using Error = cmux::TerminalHostProtocolError;
  cmux::TerminalHostSnapshot snapshot;
  snapshot.cols = 120;
  snapshot.rows = 41;
  snapshot.pid = 0x01020304;
  snapshot.replay = {0, 0xff, 'A'};
  snapshot.cwd = "/tmp/\xe2\x98\x83";
  snapshot.command = {"/bin/zsh", "-l"};

  std::vector<uint8_t> payload;
  Check(cmux::EncodeTerminalHostSnapshot(snapshot, &payload) == Error::kNone,
        "snapshot payload encodes");
  Check(payload.size() > 15 && payload[0] == 120 && payload[1] == 0 &&
            payload[2] == 41 && payload[3] == 0 && payload[4] == 4 &&
            payload[5] == 3 && payload[6] == 2 && payload[7] == 1 &&
            payload[8] == 3 && payload[9] == 0 && payload[10] == 0 &&
            payload[11] == 0 && payload[12] == 0 && payload[13] == 0xff &&
            payload[14] == 'A' && payload[15] == 1,
        "snapshot scalar and replay fields match Rust layout");
  cmux::TerminalHostSnapshot decoded;
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == snapshot,
        "snapshot round trips replay, metadata, and argv");

  cmux::TerminalHostSnapshot empty;
  empty.cols = 0;
  empty.rows = 0;
  Check(cmux::EncodeTerminalHostSnapshot(empty, &payload) == Error::kNone,
        "empty snapshot encodes");
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded.cols == 1 && decoded.rows == 1 && !decoded.pid &&
            !decoded.cwd && decoded.command.empty(),
        "snapshot decode matches Rust zero-size clamp and zero-pid sentinel");

  std::vector<uint8_t> malformed = payload;
  malformed.push_back(0);
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects trailing bytes");
  malformed = payload;
  // cols(2), rows(2), pid(4), replay length(4), empty replay, cwd tag.
  malformed[12] = 2;
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects unknown optional-string tags");
  malformed = payload;
  malformed.resize(12);
  malformed[8] = 1;
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects truncated replay");

  std::vector<uint8_t> oversized_blob = {
      80, 0, 24, 0, 0, 0, 0, 0, 1, 0x00, 0x80, 0x00,
  };
  Check(cmux::DecodeTerminalHostSnapshot(Bytes(oversized_blob), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects replay length above 8 MiB before allocation");

  cmux::TerminalHostSnapshot invalid_utf8;
  invalid_utf8.command = {std::string("\xc0\x80", 2)};
  std::vector<uint8_t> untouched = {1, 2, 3};
  Check(cmux::EncodeTerminalHostSnapshot(invalid_utf8, &untouched) ==
            Error::kMalformedPayload,
        "snapshot encoder rejects strings Rust cannot represent");
  Check(untouched == std::vector<uint8_t>({1, 2, 3}),
        "failed snapshot encode leaves destination untouched");

  cmux::TerminalHostSnapshot too_many_args;
  too_many_args.command.resize(cmux::kTerminalHostMaxCommandArguments + 1);
  Check(cmux::EncodeTerminalHostSnapshot(too_many_args, &untouched) ==
            Error::kPayloadTooLarge,
        "snapshot encoder bounds argv count");
}

void TestProtocolV2KittyAliasesAndBounds() {
  using Error = cmux::TerminalHostProtocolError;
  Check(cmux::kTerminalHostMaxSnapshotReplay ==
            kRustTerminalHostMaxReplay,
        "snapshot and resized replay limit matches Rust exactly");
  Check(cmux::kTerminalHostMaxFramePayload == 16 * 1024 * 1024,
        "terminal-host frame payload limit remains exactly 16 MiB");

  Check(KittyAliasesRoundTrip<cmux::TerminalHostSnapshot>(
            cmux::EncodeTerminalHostSnapshot,
            cmux::DecodeTerminalHostSnapshot),
        "snapshot Kitty aliases round trip after existing metadata");
  Check(KittyAliasesRoundTrip<cmux::TerminalHostResize>(
            cmux::EncodeTerminalHostResize, cmux::DecodeTerminalHostResize),
        "resized Kitty aliases round trip after replay");

  for (InvalidKittyAlias invalid :
       {InvalidKittyAlias::kZeroId, InvalidKittyAlias::kZeroNumber,
        InvalidKittyAlias::kDuplicateId,
        InvalidKittyAlias::kDuplicateNumber}) {
    Check(KittyAliasEncoderRejects<cmux::TerminalHostSnapshot>(
              cmux::EncodeTerminalHostSnapshot, invalid),
          "snapshot encoder rejects invalid Kitty alias identity");
    Check(KittyAliasDecoderRejects<cmux::TerminalHostSnapshot>(
              cmux::EncodeTerminalHostSnapshot,
              cmux::DecodeTerminalHostSnapshot, invalid),
          "snapshot decoder rejects invalid Kitty alias identity");
    Check(KittyAliasEncoderRejects<cmux::TerminalHostResize>(
              cmux::EncodeTerminalHostResize, invalid),
          "resized encoder rejects invalid Kitty alias identity");
    Check(KittyAliasDecoderRejects<cmux::TerminalHostResize>(
              cmux::EncodeTerminalHostResize,
              cmux::DecodeTerminalHostResize, invalid),
          "resized decoder rejects invalid Kitty alias identity");
  }
  Check(KittyAliasDecoderRejectsBadFraming<cmux::TerminalHostSnapshot>(
            cmux::EncodeTerminalHostSnapshot,
            cmux::DecodeTerminalHostSnapshot),
        "snapshot rejects truncated and trailing alias bytes");
  Check(KittyAliasDecoderRejectsBadFraming<cmux::TerminalHostResize>(
            cmux::EncodeTerminalHostResize, cmux::DecodeTerminalHostResize),
        "resized rejects truncated and trailing alias bytes");
  Check(KittyAliasCountIsBounded<cmux::TerminalHostSnapshot>(
            cmux::EncodeTerminalHostSnapshot),
        "snapshot admits 4096 aliases and rejects 4097");
  Check(KittyAliasCountIsBounded<cmux::TerminalHostResize>(
            cmux::EncodeTerminalHostResize),
        "resized admits 4096 aliases and rejects 4097");

  cmux::TerminalHostResize resize;
  resize.replay.resize(kRustTerminalHostMaxReplay);
  std::vector<uint8_t> payload;
  Check(cmux::EncodeTerminalHostResize(resize, &payload) == Error::kNone &&
            payload.size() == 8 + kRustTerminalHostMaxReplay + 2,
        "resized admits the exact Rust replay ceiling plus empty alias table");
  resize.replay.push_back(0);
  payload = {0xa5};
  Check(cmux::EncodeTerminalHostResize(resize, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "resized rejects one byte beyond the exact Rust replay ceiling");

  resize.replay.pop_back();
  cmux::TerminalHostSnapshot snapshot;
  snapshot.replay = std::move(resize.replay);
  Check(cmux::EncodeTerminalHostSnapshot(snapshot, &payload) == Error::kNone,
        "snapshot admits the exact Rust replay ceiling");
  snapshot.replay.push_back(0);
  payload = {0xa5};
  Check(cmux::EncodeTerminalHostSnapshot(snapshot, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "snapshot rejects one byte beyond the exact Rust replay ceiling");

  cmux::TerminalHostSnapshot oversized_frame;
  oversized_frame.replay.resize(8 * 1024 * 1024);
  oversized_frame.command.assign(
      32, std::string(cmux::kTerminalHostMaxString, 'x'));
  payload = {0xa5};
  Check(cmux::EncodeTerminalHostSnapshot(oversized_frame, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "snapshot total payload cannot exceed the exact frame cap");
}

void TestCapabilityPayloads() {
  using Error = cmux::TerminalHostProtocolError;
  using Rights = cmux::TerminalHostCapabilityRights;

  cmux::TerminalHostMintCapability request;
  request.rights = Rights::kRenderer;
  request.ttl_ms = cmux::kTerminalHostMaxRendererCapabilityTtlMs;
  std::vector<uint8_t> payload;
  Check(
      cmux::EncodeTerminalHostMintCapability(request, &payload) == Error::kNone,
      "mint-capability request encodes");
  Check(payload == std::vector<uint8_t>({7, 0, 0, 0, 0x60, 0xea, 0x00, 0x00}),
        "mint-capability request is exact rights:u32 + ttl-ms:u32 LE");
  cmux::TerminalHostMintCapability decoded;
  Check(cmux::DecodeTerminalHostMintCapability(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == request,
        "mint-capability request round trips");

  request.ttl_ms = 0;
  Check(cmux::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects zero TTL");
  request.ttl_ms = cmux::kTerminalHostMaxRendererCapabilityTtlMs + 1;
  Check(cmux::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects TTL above Rust's 60-second bound");
  request.ttl_ms = 1;
  request.rights = Rights::kInput;
  Check(cmux::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability requires read access");
  request.rights = Rights::kRead | Rights::kTerminate;
  Check(cmux::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects non-renderer rights");
  request.rights = static_cast<Rights>(1u << 31);
  Check(cmux::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects unknown rights");
  Check(cmux::DecodeTerminalHostMintCapability("short", &decoded) ==
            Error::kMalformedPayload,
        "mint-capability request has exact eight-byte width");

  const cmux::TerminalHostCapabilityToken token = Filled<32>(0xa5);
  Check(cmux::EncodeTerminalHostCapability(token, &payload) == Error::kNone,
        "capability response encodes");
  Check(payload.size() == 32 &&
            std::all_of(payload.begin(), payload.end(),
                        [](uint8_t byte) { return byte == 0xa5; }),
        "capability response is exactly the raw 32-byte one-use token");
  cmux::TerminalHostCapabilityToken decoded_token{};
  Check(cmux::DecodeTerminalHostCapability(Bytes(payload), &decoded_token) ==
                Error::kNone &&
            decoded_token == token,
        "capability response round trips");
  payload.pop_back();
  Check(cmux::DecodeTerminalHostCapability(Bytes(payload), &decoded_token) ==
            Error::kMalformedPayload,
        "capability response rejects any non-32-byte payload");
}

void TestResizeAndViewerSizePayloads() {
  using Error = cmux::TerminalHostProtocolError;
  cmux::TerminalHostResize resize;
  resize.cols = 0x0123;
  resize.rows = 0x4567;
  resize.replay = {0xaa, 0xbb, 0xcc};
  std::vector<uint8_t> payload;
  Check(cmux::EncodeTerminalHostResize(resize, &payload) == Error::kNone,
        "resized payload encodes");
  Check(payload == std::vector<uint8_t>(
                       {0x23, 0x01, 0x67, 0x45, 3, 0, 0, 0, 0xaa, 0xbb,
                        0xcc, 0, 0}),
        "resized payload matches Rust u16/u16/u32/blob/alias layout");
  cmux::TerminalHostResize decoded;
  Check(cmux::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == resize,
        "resized payload round trips");
  payload.push_back(0);
  Check(cmux::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
            Error::kMalformedPayload,
        "resized payload rejects trailing bytes");
  payload.resize(8);
  payload[4] = 4;
  Check(cmux::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
            Error::kMalformedPayload,
        "resized payload rejects truncated replay");

  Check(cmux::EncodeTerminalHostViewerSize(0, 0, &payload) == Error::kNone &&
            payload == std::vector<uint8_t>({1, 0, 1, 0}),
        "viewer-size encoder matches Rust minimum clamp");
  uint16_t cols = 0;
  uint16_t rows = 0;
  Check(cmux::DecodeTerminalHostViewerSize(Bytes(payload), &cols, &rows) ==
                Error::kNone &&
            cols == 1 && rows == 1,
        "viewer-size payload decodes");
  payload.push_back(0);
  Check(cmux::DecodeTerminalHostViewerSize(Bytes(payload), &cols, &rows) ==
            Error::kMalformedPayload,
        "viewer-size payload has exact four-byte width");

  cmux::TerminalHostResizeAck ack;
  ack.cols = 80;
  ack.rows = 24;
  ack.result_flags = cmux::kTerminalHostResizeAckCanonicalChanged;
  Check(cmux::EncodeTerminalHostResizeAck(ack, &payload) == Error::kNone &&
            payload == std::vector<uint8_t>({80, 0, 24, 0, 1, 0, 0, 0}),
        "resize acknowledgement has exact canonical-grid/result layout");
  cmux::TerminalHostResizeAck decoded_ack;
  Check(cmux::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
                Error::kNone &&
            decoded_ack == ack,
        "resize acknowledgement round trips");
  payload.push_back(0);
  Check(cmux::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
            Error::kMalformedPayload,
        "resize acknowledgement rejects trailing bytes");
  payload.resize(8);
  payload[4] = 2;
  Check(cmux::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
            Error::kMalformedPayload,
        "resize acknowledgement rejects unknown result flags");
  ack.result_flags = 2;
  Check(cmux::EncodeTerminalHostResizeAck(ack, &payload) ==
            Error::kMalformedPayload,
        "resize acknowledgement encoder rejects unknown result flags");
}

void TestColorMetadataSetThenReset() {
  cmux::TerminalHostColors colors;
  colors.foreground = cmux::TerminalHostRgb{1, 2, 3};
  colors.cursor = cmux::TerminalHostRgb{0xaa, 0xbb, 0xcc};
  colors.cursor_visual = cmux::TerminalHostCursorVisual{
      cmux::TerminalHostCursorStyle::kUnderline, false};
  colors.palette.push_back(
      cmux::TerminalHostPaletteEntry{4, {0x10, 0x20, 0x30}});
  std::vector<uint8_t> metadata = {'x'};
  cmux::AppendTerminalHostColorMetadata(colors, &metadata);
  Check(Bytes(metadata) ==
            "x\x1b]104\a\x1b]4;4;rgb:10/20/30\a"
            "\x1b]10;rgb:01/02/03\a\x1b]111\a"
            "\x1b]12;rgb:aa/bb/cc\a\x1b[0 q\x1b[4 q",
        "full color metadata resets palette, sets sparse entries, and resets "
        "an absent background before applying the authoritative cursor");

  metadata.clear();
  cmux::AppendTerminalHostColorMetadata(cmux::TerminalHostColors(), &metadata);
  Check(Bytes(metadata) ==
            "\x1b]104\a\x1b]110\a\x1b]111\a\x1b]112\a",
        "legacy sparse state resets every prior color without inventing a "
        "cursor reset");

  struct CursorCase {
    cmux::TerminalHostCursorStyle style;
    bool blinking;
    char decscusr;
  };
  constexpr std::array<CursorCase, 6> kCursorCases = {{
      {cmux::TerminalHostCursorStyle::kBlock, true, '1'},
      {cmux::TerminalHostCursorStyle::kBlock, false, '2'},
      {cmux::TerminalHostCursorStyle::kUnderline, true, '3'},
      {cmux::TerminalHostCursorStyle::kUnderline, false, '4'},
      {cmux::TerminalHostCursorStyle::kBar, true, '5'},
      {cmux::TerminalHostCursorStyle::kBar, false, '6'},
  }};
  for (const CursorCase& cursor_case : kCursorCases) {
    cmux::TerminalHostColors cursor_colors;
    cursor_colors.cursor_visual = cmux::TerminalHostCursorVisual{
        cursor_case.style, cursor_case.blinking};
    metadata.clear();
    cmux::AppendTerminalHostColorMetadata(cursor_colors, &metadata);
    std::string expected =
        "\x1b]104\a\x1b]110\a\x1b]111\a\x1b]112\a\x1b[0 q\x1b[";
    expected.push_back(cursor_case.decscusr);
    expected.append(" q");
    Check(Bytes(metadata) == expected,
          "cursor metadata maps shape and blink to exact DECSCUSR");
  }

  cmux::AppendTerminalHostColorMetadata(colors, nullptr);
  Check(true, "null color metadata destination is ignored safely");
}

void TestAuthoritativeCursorMetadataFollowsReplay() {
  cmux::TerminalHostColors mode12_colors;
  mode12_colors.cursor_visual = cmux::TerminalHostCursorVisual{
      cmux::TerminalHostCursorStyle::kBar, false};
  std::vector<uint8_t> replacement = {'\x1b', 'c'};
  constexpr std::string_view kBlinkingReplay = "\x1b[?12h";
  replacement.insert(replacement.end(), kBlinkingReplay.begin(),
                     kBlinkingReplay.end());
  cmux::AppendTerminalHostColorMetadata(mode12_colors, &replacement);
  Check(Bytes(replacement) ==
            "\x1b\x63\x1b[?12h\x1b]104\a\x1b]110\a\x1b]111\a"
            "\x1b]112\a\x1b[0 q\x1b[6 q",
        "resolved mode-12 state wins after authoritative replay reset");

  cmux::TerminalHostColors primary_colors;
  primary_colors.cursor_visual = cmux::TerminalHostCursorVisual{
      cmux::TerminalHostCursorStyle::kBlock, true};
  replacement = {'\x1b', 'c'};
  constexpr std::string_view kAlternateReplay =
      "\x1b[?1049h\x1b[4 q\x1b[?12l\x1b[?1049l";
  replacement.insert(replacement.end(), kAlternateReplay.begin(),
                     kAlternateReplay.end());
  cmux::AppendTerminalHostColorMetadata(primary_colors, &replacement);
  constexpr std::string_view kResolvedPrimary = "\x1b[0 q\x1b[1 q";
  const std::string_view replacement_bytes = Bytes(replacement);
  Check(
      replacement_bytes.size() >= kResolvedPrimary.size() &&
          replacement_bytes.substr(replacement_bytes.size() -
                                   kResolvedPrimary.size()) == kResolvedPrimary,
      "resolved primary-screen cursor pair wins after alternate replay");
}

void TestLegacyCursorAbsencePreservesOutputAndReplay() {
  // Decode the exact v1 shape a rolling upgrade receives. Cursor metadata did
  // not exist in v1, so its absence is unknown rather than a reset request.
  constexpr std::array<uint8_t, 11> kLegacyColorsPayload = {
      1, 0,  // Colors schema v1.
      1, 0,  // Foreground only; no cursor-visual flag.
      0, 0,  // No palette entries.
      0, 0,  // Reserved.
      1, 2, 3,
  };
  cmux::TerminalHostColors legacy_colors;
  Check(cmux::DecodeTerminalHostColors(
            std::string_view(
                reinterpret_cast<const char*>(kLegacyColorsPayload.data()),
                kLegacyColorsPayload.size()),
            &legacy_colors) == cmux::TerminalHostProtocolError::kNone &&
            !legacy_colors.cursor_visual,
        "legacy Colors fixture decodes without cursor authority");

  std::vector<uint8_t> live;
  constexpr std::string_view kLiveOutput =
      "\x1b[5 q\x1b[?12l\x1b]10;rgb:01/02/03\a";
  live.insert(live.end(), kLiveOutput.begin(), kLiveOutput.end());
  cmux::AppendTerminalHostColorMetadata(legacy_colors, &live);
  Check(Bytes(live) ==
            "\x1b[5 q\x1b[?12l\x1b]10;rgb:01/02/03\a"
            "\x1b]104\a\x1b]10;rgb:01/02/03\a\x1b]111\a\x1b]112\a",
        "live v1 color metadata preserves preceding DECSCUSR and mode 12");

  std::vector<uint8_t> replay = {'\x1b', 'c'};
  constexpr std::string_view kReplayCursor = "\x1b[3 q\x1b[?12l";
  replay.insert(replay.end(), kReplayCursor.begin(), kReplayCursor.end());
  cmux::AppendTerminalHostColorMetadata(legacy_colors, &replay);
  Check(Bytes(replay) ==
            "\x1b\x63\x1b[3 q\x1b[?12l"
            "\x1b]104\a\x1b]10;rgb:01/02/03\a\x1b]111\a\x1b]112\a",
        "v1 replay keeps its post-RIS cursor state when metadata is absent");
}

}  // namespace

int main() {
  TestFrameGoldenAndKinds();
  TestRendererGrantValidation();
  TestFragmentationAndCoalescing();
  TestMalformedFrames();
  TestHelloPayloads();
  TestCapabilityPayloads();
  TestSnapshotPayload();
  TestProtocolV2KittyAliasesAndBounds();
  TestResizeAndViewerSizePayloads();
  TestColorMetadataSetThenReset();
  TestAuthoritativeCursorMetadataFollowsReplay();
  TestLegacyCursorAbsencePreservesOutputAndReplay();
  std::printf("cmux-terminal-host-protocol: %d checks, %d failures\n", checks,
              failures);
  return failures == 0 ? 0 : 1;
}
