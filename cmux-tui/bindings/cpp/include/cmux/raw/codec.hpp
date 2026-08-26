#pragma once

#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

#include "cmux/raw/field.hpp"
#include "cmux/json.hpp"

namespace cmux::raw {

template <typename T, typename Enable = void>
struct Codec;

template <typename T>
[[nodiscard]] Result<Json> encode_value(const T& value) {
    return Codec<T>::encode(value);
}

template <typename T>
[[nodiscard]] Result<T> decode_value(const Json& value) {
    return Codec<T>::decode(value);
}

template <>
struct Codec<Json> {
    static Result<Json> encode(const Json& value) { return value; }
    static Result<Json> decode(const Json& value) { return value; }
};

template <>
struct Codec<bool> {
    static Result<Json> encode(bool value) { return Json(value); }
    static Result<bool> decode(const Json& value) { return value.as_bool(); }
};

template <>
struct Codec<std::string> {
    static Result<Json> encode(const std::string& value) { return Json(value); }
    static Result<std::string> decode(const Json& value) {
        auto result = value.as_string();
        if (!result) {
            return std::move(result).error();
        }
        return std::string(result.value());
    }
};

template <typename T>
struct Codec<
    T,
    std::enable_if_t<std::is_integral_v<T> && std::is_signed_v<T> &&
                     !std::is_same_v<T, bool>>> {
    static Result<Json> encode(T value) { return Json(static_cast<std::int64_t>(value)); }
    static Result<T> decode(const Json& value) {
        auto integer = value.as_int64();
        if (!integer) {
            return std::move(integer).error();
        }
        if (integer.value() < static_cast<std::int64_t>(std::numeric_limits<T>::min()) ||
            integer.value() > static_cast<std::int64_t>(std::numeric_limits<T>::max())) {
            return make_error(ErrorCode::decode, "signed integer is outside the target type range");
        }
        return static_cast<T>(integer.value());
    }
};

template <typename T>
struct Codec<T, std::enable_if_t<std::is_integral_v<T> && std::is_unsigned_v<T>>> {
    static Result<Json> encode(T value) { return Json(static_cast<std::uint64_t>(value)); }
    static Result<T> decode(const Json& value) {
        auto integer = value.as_uint64();
        if (!integer) {
            return std::move(integer).error();
        }
        if (integer.value() > static_cast<std::uint64_t>(std::numeric_limits<T>::max())) {
            return make_error(
                ErrorCode::decode, "unsigned integer is outside the target type range");
        }
        return static_cast<T>(integer.value());
    }
};

template <typename T>
struct Codec<T, std::enable_if_t<std::is_floating_point_v<T>>> {
    static Result<Json> encode(T value) { return Json(static_cast<double>(value)); }
    static Result<T> decode(const Json& value) {
        auto number = value.as_double();
        if (!number) {
            return std::move(number).error();
        }
        if (number.value() < -static_cast<double>(std::numeric_limits<T>::max()) ||
            number.value() > static_cast<double>(std::numeric_limits<T>::max())) {
            return make_error(
                ErrorCode::decode, "number is outside the target floating-point range");
        }
        return static_cast<T>(number.value());
    }
};

template <typename T>
struct Codec<std::vector<T>> {
    static Result<Json> encode(const std::vector<T>& values) {
        Json::Array array;
        array.reserve(values.size());
        for (const auto& value : values) {
            auto encoded = encode_value(value);
            if (!encoded) {
                return std::move(encoded).error();
            }
            array.push_back(std::move(encoded).value());
        }
        return Json(std::move(array));
    }

    static Result<std::vector<T>> decode(const Json& value) {
        auto source = value.as_array();
        if (!source) {
            return std::move(source).error();
        }
        std::vector<T> result;
        result.reserve(source.value()->size());
        for (const auto& item : *source.value()) {
            auto decoded = decode_value<T>(item);
            if (!decoded) {
                return std::move(decoded).error();
            }
            result.push_back(std::move(decoded).value());
        }
        return result;
    }
};

template <typename T>
struct Codec<std::map<std::string, T, std::less<>>> {
    using Map = std::map<std::string, T, std::less<>>;

    static Result<Json> encode(const Map& values) {
        Json::Object object;
        for (const auto& [key, value] : values) {
            auto encoded = encode_value(value);
            if (!encoded) {
                return std::move(encoded).error();
            }
            object.emplace(key, std::move(encoded).value());
        }
        return Json(std::move(object));
    }

    static Result<Map> decode(const Json& value) {
        auto source = value.as_object();
        if (!source) {
            return std::move(source).error();
        }
        Map result;
        for (const auto& [key, item] : *source.value()) {
            auto decoded = decode_value<T>(item);
            if (!decoded) {
                return std::move(decoded).error();
            }
            result.emplace(key, std::move(decoded).value());
        }
        return result;
    }
};

template <typename T>
struct Codec<std::optional<T>> {
    static Result<Json> encode(const std::optional<T>& value) {
        return value ? encode_value(*value) : Result<Json>(Json(nullptr));
    }
    static Result<std::optional<T>> decode(const Json& value) {
        if (value.is_null()) {
            return std::optional<T>{};
        }
        auto decoded = decode_value<T>(value);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return std::optional<T>(std::move(decoded).value());
    }
};

template <typename T>
struct Codec<Field<T>> {
    static Result<Json> encode(const Field<T>& value) {
        if (value.is_absent()) {
            return make_error(
                ErrorCode::invalid_argument, "an absent field cannot be encoded as a JSON value");
        }
        return value.is_null() ? Result<Json>(Json(nullptr)) : encode_value(value.value());
    }
    static Result<Field<T>> decode(const Json& value) {
        if (value.is_null()) {
            return Field<T>::null();
        }
        auto decoded = decode_value<T>(value);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return Field<T>(std::move(decoded).value());
    }
};

template <typename T>
struct Codec<std::shared_ptr<T>> {
    static Result<Json> encode(const std::shared_ptr<T>& value) {
        if (!value) {
            return make_error(ErrorCode::invalid_argument, "required recursive value is null");
        }
        return encode_value(*value);
    }
    static Result<std::shared_ptr<T>> decode(const Json& value) {
        auto decoded = decode_value<T>(value);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return std::make_shared<T>(std::move(decoded).value());
    }
};

namespace detail {

template <typename Variant, std::size_t Index = 0>
Result<Variant> decode_variant(const Json& value) {
    if constexpr (Index == std::variant_size_v<Variant>) {
        return make_error(ErrorCode::decode, "JSON value did not match any union variant");
    } else {
        using Alternative = std::variant_alternative_t<Index, Variant>;
        auto decoded = decode_value<Alternative>(value);
        if (decoded) {
            return Variant(std::in_place_index<Index>, std::move(decoded).value());
        }
        return decode_variant<Variant, Index + 1>(value);
    }
}

}  // namespace detail

template <typename... T>
struct Codec<std::variant<T...>> {
    using Variant = std::variant<T...>;

    static Result<Json> encode(const Variant& value) {
        return std::visit(
            [](const auto& item) -> Result<Json> { return encode_value(item); }, value);
    }
    static Result<Variant> decode(const Json& value) {
        return detail::decode_variant<Variant>(value);
    }
};

}  // namespace cmux::raw
