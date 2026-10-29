// The arguments of one generated op (scripts/cmux-next/gen-chromium-host-wire.py) as control
// channel fields (chromium_host_control.h), for both ends: the remote shim writes the call and
// reads mirror values (../client/remote_shim.mm), the host reads the call and writes mirror
// values and replies (host_dispatch.mm). Header-only, no CEF.
//
// Fields are positional, in the order the generated code writes them, like the parameters of
// a mojom method (mojo/public/tools/bindings/generators/cpp_templates/struct_macros.tmpl). The
// tag carries one flag, kTagNull: a NULL const char* or a NULL buffer, which the header gives a
// different meaning from "" (an empty payload with kTagValue).
//
//   I32 U32  an i32 field (U32 as its bit pattern)
//   I64 F64  an i64 or f64 field
//   Str      a str field, or a bytes field when the text is not UTF-8 (a file name can be any
//            bytes; a str field must be valid UTF-8 or the frame is malformed)
//   Bytes    a bytes field
//   View     an i64 field: the page view token (ChromiumHostPageView, task 040)
//   StrList  an i32 count, then that many Str fields
//   I32Array a bytes field of little-endian int32 values
//
// A list of fields nested in one bytes field (a mirror key or value, a reply) is the frame
// body's own encoding, EncodeFields: u8 type | u8 tag | u16 length | length bytes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "chromium_host_control.h"

namespace cmux_host::control {

inline constexpr uint8_t kTagValue = 0;
inline constexpr uint8_t kTagNull = 1;

// The first frame each side sends on a connection, next to the generated kOpEvent..kOpAck:
//   cmux -> host  str kWireID, str kShimAbiID
//   host -> cmux  str kWireID, StrList of the optional_exports its shim defines; sent after the
//                 MIRROR values whose only refresh event is attach (the `attach` pseudo event)
// A HELLO with another kWireID (another generation of the op table) is malformed.
inline constexpr uint16_t kOpHello = 0x8005;
// Host -> cmux: the pointer moves and wheel ticks of one input batch the host dispatched on its
// UI thread (ring frames, chromium_host_input_ring.h). One record per
// frame, oldest first, at least one: i32 client browser, i32 kind (kMouse or kWheel of
// chromium_host_wire.h), u32 the frame's input seq. cmux sends the page's next move or wheel
// tick on it (ChromiumHostInputPacer), as Chrome's MouseWheelEventQueue sends its next event
// on the ack (components/input/mouse_wheel_event_queue.cc). Any other kind is malformed.
inline constexpr uint16_t kOpInputAck = 0x8006;

// Little-endian helpers of EncodeFields and DecodeFields.
inline void PutLE(std::string* out, uint64_t value, size_t size) {
  for (size_t i = 0; i < size; ++i) out->push_back(static_cast<char>(value >> (8 * i)));
}
inline uint64_t GetLE(std::string_view in) {
  uint64_t value = 0;
  for (size_t i = 0; i < in.size(); ++i) value |= static_cast<uint64_t>(static_cast<uint8_t>(in[i])) << (8 * i);
  return value;
}

// The fields of `fields` encoded as a frame body, appended to `out`; false (nothing
// appended) when a field is over 65,535 bytes.
inline bool EncodeFields(const std::vector<Field>& fields, std::string* out) {
  std::string body;
  for (const Field& field : fields) {
    const bool fixed = field.type == Type::kI32 || field.type == Type::kI64 || field.type == Type::kF64;
    const size_t length = field.type == Type::kI32 ? 4 : fixed ? 8 : field.bytes.size();
    if (length > 0xffff) return false;
    body.push_back(static_cast<char>(field.type));
    body.push_back(static_cast<char>(field.tag));
    PutLE(&body, length, 2);
    if (field.type == Type::kF64) {
      uint64_t bits = 0;
      std::memcpy(&bits, &field.real, sizeof bits);
      PutLE(&body, bits, 8);
    } else if (fixed) {
      PutLE(&body, static_cast<uint64_t>(field.integer), length);
    } else {
      body.append(field.bytes);
    }
  }
  out->append(body);
  return true;
}

// The fields of an EncodeFields body; false for a malformed one (an unknown type, a fixed
// field of the wrong size, a field past the end, a str field that is not UTF-8).
inline bool DecodeFields(std::string_view body, std::vector<Field>* out) {
  std::vector<Field> fields;
  while (!body.empty()) {
    if (body.size() < kFieldHeaderSize) return false;
    const auto type = static_cast<Type>(body[0]);
    const auto tag = static_cast<uint8_t>(body[1]);
    const size_t length = GetLE(body.substr(2, 2));
    if (body.size() - kFieldHeaderSize < length) return false;
    const std::string_view value = body.substr(kFieldHeaderSize, length);
    switch (type) {
      case Type::kI32:
        if (length != 4) return false;
        fields.push_back(Field::I32(tag, static_cast<int32_t>(static_cast<uint32_t>(GetLE(value)))));
        break;
      case Type::kI64:
        if (length != 8) return false;
        fields.push_back(Field::I64(tag, static_cast<int64_t>(GetLE(value))));
        break;
      case Type::kF64: {
        if (length != 8) return false;
        const uint64_t bits = GetLE(value);
        double real = 0;
        std::memcpy(&real, &bits, sizeof real);
        fields.push_back(Field::F64(tag, real));
        break;
      }
      case Type::kBytes:
        fields.push_back(Field::Bytes(tag, std::string(value)));
        break;
      case Type::kStr:
        fields.push_back(Field::Str(tag, std::string(value)));
        if (!IsValidUtf8(fields.back().bytes)) return false;
        break;
      default:
        return false;
    }
    body.remove_prefix(kFieldHeaderSize + length);
  }
  *out = std::move(fields);
  return true;
}

class TlvWriter {
 public:
  void I32(int32_t value) { fields_.push_back(Field::I32(kTagValue, value)); }
  void U32(uint32_t value) { I32(static_cast<int32_t>(value)); }
  void I64(int64_t value) { fields_.push_back(Field::I64(kTagValue, value)); }
  void F64(double value) { fields_.push_back(Field::F64(kTagValue, value)); }
  void Str(const char* text) {
    if (text == nullptr) {
      fields_.push_back(Field::Str(kTagNull, std::string()));
      return;
    }
    std::string value(text);
    if (IsValidUtf8(value)) {
      fields_.push_back(Field::Str(kTagValue, std::move(value)));
    } else {
      fields_.push_back(Field::Bytes(kTagValue, std::move(value)));
    }
  }
  void Bytes(const void* data, size_t length) {
    if (data == nullptr) {
      fields_.push_back(Field::Bytes(kTagNull, std::string()));
      return;
    }
    fields_.push_back(Field::Bytes(kTagValue, std::string(static_cast<const char*>(data), length)));
  }
  void ViewToken(uint64_t token) { I64(static_cast<int64_t>(token)); }
  void StrList(const char* const* list, int count) {
    const int n = list != nullptr && count > 0 ? count : 0;
    I32(n);
    for (int i = 0; i < n; ++i) Str(list[i]);
  }
  void I32Array(const int* values, size_t count) {
    std::string bytes;
    bytes.reserve(count * 4);
    for (size_t i = 0; i < count; ++i) PutLE(&bytes, static_cast<uint32_t>(values[i]), 4);
    fields_.push_back(Field::Bytes(kTagValue, std::move(bytes)));
  }

  const std::vector<Field>& fields() const { return fields_; }
  std::vector<Field> Take() { return std::move(fields_); }
  // The fields as one nested body (EncodeFields); false when a field is too large.
  bool Encode(std::string* out) const { return EncodeFields(fields_, out); }

 private:
  std::vector<Field> fields_;
};

// Reads fields in order. A read of the wrong type, or past the end, returns the zero value
// and makes ok() false; the caller checks ok() (and AtEnd()) once at the end.
class TlvReader {
 public:
  // No value (a mirror key the host never pushed): present() is false.
  TlvReader() = default;
  explicit TlvReader(std::vector<Field> fields) : present_(true), fields_(std::move(fields)) {}

  bool present() const { return present_; }
  bool ok() const { return ok_; }
  bool AtEnd() const { return next_ == fields_.size(); }

  int32_t I32() {
    const Field* field = Next(Type::kI32);
    return field ? static_cast<int32_t>(field->integer) : 0;
  }
  uint32_t U32() { return static_cast<uint32_t>(I32()); }
  int64_t I64() {
    const Field* field = Next(Type::kI64);
    return field ? field->integer : 0;
  }
  double F64() {
    const Field* field = Next(Type::kF64);
    return field ? field->real : 0;
  }
  // nullopt for a NULL string.
  std::optional<std::string> Str() {
    const Field* field = NextBytes();
    if (field == nullptr || field->tag == kTagNull) return std::nullopt;
    return field->bytes;
  }
  // "" for a NULL buffer.
  std::string Bytes() {
    const Field* field = NextBytes();
    return field ? field->bytes : std::string();
  }
  uint64_t View() { return static_cast<uint64_t>(I64()); }
  std::vector<std::string> StrList() {
    std::vector<std::string> out;
    const int32_t count = I32();
    if (count < 0 || static_cast<size_t>(count) > fields_.size() - next_) {
      ok_ = false;
      return out;
    }
    out.reserve(static_cast<size_t>(count));
    for (int32_t i = 0; i < count; ++i) out.push_back(Str().value_or(std::string()));
    return out;
  }
  // Copies up to `capacity` values into `out`; returns how many the field holds.
  int I32Array(int* out, int capacity) {
    const Field* field = Next(Type::kBytes);
    if (field == nullptr) return 0;
    if (field->bytes.size() % 4 != 0) {
      ok_ = false;
      return 0;
    }
    const auto count = static_cast<int>(field->bytes.size() / 4);
    for (int i = 0; out != nullptr && i < count && i < capacity; ++i) {
      const auto bits = static_cast<uint32_t>(GetLE(std::string_view(field->bytes).substr(static_cast<size_t>(i) * 4, 4)));
      out[i] = static_cast<int>(bits);
    }
    return count;
  }

 private:
  const Field* Next(Type type) {
    if (!ok_ || next_ >= fields_.size() || fields_[next_].type != type) {
      ok_ = false;
      return nullptr;
    }
    return &fields_[next_++];
  }
  const Field* NextBytes() {
    if (ok_ && next_ < fields_.size() && fields_[next_].type == Type::kStr) return &fields_[next_++];
    return Next(Type::kBytes);
  }

  bool present_ = false;
  bool ok_ = true;
  std::vector<Field> fields_;
  size_t next_ = 0;
};

}  // namespace cmux_host::control
