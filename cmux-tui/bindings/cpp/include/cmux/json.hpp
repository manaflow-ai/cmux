#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "cmux/result.hpp"

namespace cmux {

struct JsonLimits {
    std::size_t max_input_bytes = 16U * 1024U * 1024U;
    std::size_t max_depth = 64;
    std::size_t max_nodes = 1'000'000;
    std::size_t max_string_bytes = 8U * 1024U * 1024U;
};

class Json {
public:
    using Array = std::vector<Json>;
    using Object = std::map<std::string, Json, std::less<>>;
    using Value =
        std::variant<std::nullptr_t, bool, std::int64_t, std::uint64_t, double, std::string, Array, Object>;

    Json() noexcept : value_(nullptr) {}
    Json(std::nullptr_t) noexcept : value_(nullptr) {}
    Json(bool value) noexcept : value_(value) {}
    Json(std::int32_t value) noexcept : value_(static_cast<std::int64_t>(value)) {}
    Json(std::uint32_t value) noexcept : value_(static_cast<std::uint64_t>(value)) {}
    Json(std::int64_t value) noexcept : value_(value) {}
    Json(std::uint64_t value) noexcept : value_(value) {}
    Json(double value) noexcept : value_(value) {}
    Json(const char* value) : value_(std::string(value)) {}
    Json(std::string value) : value_(std::move(value)) {}
    Json(Array value) : value_(std::move(value)) {}
    Json(Object value) : value_(std::move(value)) {}

    [[nodiscard]] static Result<Json> parse(std::string_view input, JsonLimits limits = {});
    [[nodiscard]] Result<std::string> encode(JsonLimits limits = {}) const;

    [[nodiscard]] bool is_null() const noexcept;
    [[nodiscard]] bool is_bool() const noexcept;
    [[nodiscard]] bool is_integer() const noexcept;
    [[nodiscard]] bool is_number() const noexcept;
    [[nodiscard]] bool is_string() const noexcept;
    [[nodiscard]] bool is_array() const noexcept;
    [[nodiscard]] bool is_object() const noexcept;

    [[nodiscard]] const Value& value() const noexcept { return value_; }
    [[nodiscard]] Value& value() noexcept { return value_; }

    [[nodiscard]] Result<bool> as_bool() const;
    [[nodiscard]] Result<std::int64_t> as_int64() const;
    [[nodiscard]] Result<std::uint64_t> as_uint64() const;
    [[nodiscard]] Result<double> as_double() const;
    [[nodiscard]] Result<std::string_view> as_string() const;
    [[nodiscard]] Result<const Array*> as_array() const;
    [[nodiscard]] Result<const Object*> as_object() const;
    [[nodiscard]] Result<Array*> as_array();
    [[nodiscard]] Result<Object*> as_object();

    [[nodiscard]] const Json* find(std::string_view key) const noexcept;
    [[nodiscard]] Json* find(std::string_view key) noexcept;

    friend bool operator==(const Json&, const Json&) = default;

private:
    Value value_;
};

[[nodiscard]] Result<const Json*> require_field(const Json& object, std::string_view name);
[[nodiscard]] Result<std::string> require_string(const Json& object, std::string_view name);
[[nodiscard]] Result<std::uint64_t> require_uint64(const Json& object, std::string_view name);
[[nodiscard]] Result<std::int64_t> require_int64(const Json& object, std::string_view name);
[[nodiscard]] Result<bool> require_bool(const Json& object, std::string_view name);

}  // namespace cmux
