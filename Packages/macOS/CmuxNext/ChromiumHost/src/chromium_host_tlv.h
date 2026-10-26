// The values of one generated op on the control channel
// (chromium_host_control.h): the arguments of a `cmux_shim_*` call, a reply,
// a mirror key or value, in argument order, one control::Field each. The
// generated host_dispatch.inc and remote_shim.inc
// (scripts/cmux-next/gen-chromium-host-wire.py) read and write them through
// these two classes, as Mojo's generated stubs read a message through
// mojo/public/cpp/bindings/lib/serialization.h. Needs no CEF:
// ../tests/chromium_host_tlv_test.cpp runs anywhere.
//
// Encoding, by C type:
//   int, unsigned        i32 (unsigned as its bit pattern)
//   int64_t              i64
//   double               f64
//   const char*          str; NULL is a str field with tag kTagNull, apart from ""
//   bytes + length       bytes
//   NSView* (a token)    i64, the page view token (0: none)
//   const char* list     i32 count, then count str fields
//   int out-array        bytes, little-endian int32 each, tag kTagI32Array
// Field tags carry only these markers; position gives the meaning, and the
// header's argument list (the op id) gives the positions.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "chromium_host_control.h"

namespace cmux_host::tlv {

inline constexpr uint8_t kTagValue = 0;
inline constexpr uint8_t kTagNull = 1;
inline constexpr uint8_t kTagI32Array = 2;

class Writer {
 public:
  void I32(int32_t value) { Add(control::Type::kI32, kTagValue).integer = value; }
  void U32(uint32_t value) { I32(static_cast<int32_t>(value)); }
  void I64(int64_t value) { Add(control::Type::kI64, kTagValue).integer = value; }
  void F64(double value) { Add(control::Type::kF64, kTagValue).real = value; }
  void Str(const char* text) {
    control::Field& field = Add(control::Type::kStr, text ? kTagValue : kTagNull);
    if (text) field.bytes = text;
  }
  void Bytes(const void* data, size_t length) {
    control::Field& field = Add(control::Type::kBytes, kTagValue);
    if (data && length) field.bytes.assign(static_cast<const char*>(data), length);
  }
  void ViewToken(uint64_t token) { I64(static_cast<int64_t>(token)); }
  void StrList(const char* const* items, int count) {
    const int n = items && count > 0 ? count : 0;
    I32(n);
    for (int i = 0; i < n; ++i) Str(items[i] ? items[i] : "");
  }
  void I32Array(const int* values, size_t count) {
    control::Field& field = Add(control::Type::kBytes, kTagI32Array);
    field.bytes.resize(count * 4);
    for (size_t i = 0; i < count; ++i) {
      const uint32_t bits = static_cast<uint32_t>(values[i]);
      for (size_t b = 0; b < 4; ++b) field.bytes[i * 4 + b] = static_cast<char>((bits >> (8 * b)) & 0xff);
    }
  }
  // Every field of `other`, in order (a mirror key followed by its value).
  void Append(const Writer& other) { fields_.insert(fields_.end(), other.fields_.begin(), other.fields_.end()); }

  const std::vector<control::Field>& fields() const { return fields_; }
  std::vector<control::Field> Take() { return std::move(fields_); }

 private:
  control::Field& Add(control::Type type, uint8_t tag) {
    control::Field& field = fields_.emplace_back();
    field.type = type;
    field.tag = tag;
    return field;
  }

  std::vector<control::Field> fields_;
};

// Reads fields [begin, end) of a message in order. A field of the wrong type
// or tag, or a read past the end, makes ok() false and returns a zero value;
// the generated code checks ok() and AtEnd() once, after the last read, and a
// message that fails ends the connection (chromium_host_control.h, bounds).
class Reader {
 public:
  explicit Reader(const std::vector<control::Field>& fields) : Reader(fields, 0, fields.size()) {}
  Reader(const std::vector<control::Field>& fields, size_t begin, size_t end)
      : fields_(fields), next_(begin), end_(end <= fields.size() ? end : fields.size()) {}

  int32_t I32() {
    const control::Field* field = Next(control::Type::kI32);
    return field ? static_cast<int32_t>(field->integer) : 0;
  }
  uint32_t U32() { return static_cast<uint32_t>(I32()); }
  int64_t I64() {
    const control::Field* field = Next(control::Type::kI64);
    return field ? field->integer : 0;
  }
  double F64() {
    const control::Field* field = Next(control::Type::kF64);
    return field ? field->real : 0;
  }
  std::optional<std::string> Str() {
    if (!ok_ || next_ >= end_ || fields_[next_].type != control::Type::kStr) return Fail<std::optional<std::string>>();
    const control::Field& field = fields_[next_++];
    if (field.tag == kTagNull && field.bytes.empty()) return std::nullopt;
    if (field.tag != kTagValue) return Fail<std::optional<std::string>>();
    return field.bytes;
  }
  std::string Bytes() {
    const control::Field* field = Next(control::Type::kBytes);
    return field ? field->bytes : std::string();
  }
  uint64_t View() { return static_cast<uint64_t>(I64()); }
  std::vector<std::string> StrList() {
    const int32_t count = I32();
    if (!ok_ || count < 0 || static_cast<size_t>(count) > end_ - next_) return Fail<std::vector<std::string>>();
    std::vector<std::string> items;
    items.reserve(static_cast<size_t>(count));
    for (int32_t i = 0; i < count; ++i) {
      std::optional<std::string> item = Str();
      if (!item) return Fail<std::vector<std::string>>();  // a list holds no NULL
      items.push_back(std::move(*item));
    }
    return items;
  }
  // An out-array (I32Array of the writer): at most `capacity` values copied.
  int I32Array(int* out, int capacity) {
    if (!ok_ || next_ >= end_ || fields_[next_].type != control::Type::kBytes ||
        fields_[next_].tag != kTagI32Array || fields_[next_].bytes.size() % 4 != 0) {
      return Fail<int>();
    }
    const std::string& bytes = fields_[next_++].bytes;
    const int count = static_cast<int>(bytes.size() / 4);
    for (int i = 0; i < count && i < capacity; ++i) {
      uint32_t bits = 0;
      for (int b = 0; b < 4; ++b) bits |= static_cast<uint32_t>(static_cast<uint8_t>(bytes[i * 4 + b])) << (8 * b);
      out[i] = static_cast<int>(bits);
    }
    return count;
  }

  bool present() const { return ok_ && next_ < end_; }
  bool ok() const { return ok_; }
  bool AtEnd() const { return next_ == end_; }
  size_t position() const { return next_; }

 private:
  const control::Field* Next(control::Type type) {
    if (!ok_ || next_ >= end_ || fields_[next_].type != type || fields_[next_].tag != kTagValue) {
      ok_ = false;
      return nullptr;
    }
    return &fields_[next_++];
  }
  template <typename T>
  T Fail() {
    ok_ = false;
    return T();
  }

  const std::vector<control::Field>& fields_;
  size_t next_;
  const size_t end_;
  bool ok_ = true;
};

}  // namespace cmux_host::tlv
