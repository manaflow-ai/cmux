#include "cmux/json.hpp"

#include <charconv>
#include <cmath>
#include <limits>
#include <sstream>

namespace cmux {
namespace {

[[nodiscard]] Error decode_error(std::string message) {
    return make_error(ErrorCode::decode, std::move(message));
}

[[nodiscard]] bool valid_utf8(std::string_view value) {
    std::size_t index = 0;
    while (index < value.size()) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t width = 0;
        std::uint32_t codepoint = 0;
        if (first <= 0x7fU) {
            ++index;
            continue;
        }
        if ((first & 0xe0U) == 0xc0U) {
            width = 2;
            codepoint = first & 0x1fU;
        } else if ((first & 0xf0U) == 0xe0U) {
            width = 3;
            codepoint = first & 0x0fU;
        } else if ((first & 0xf8U) == 0xf0U) {
            width = 4;
            codepoint = first & 0x07U;
        } else {
            return false;
        }
        if (index + width > value.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset < width; ++offset) {
            const auto byte = static_cast<unsigned char>(value[index + offset]);
            if ((byte & 0xc0U) != 0x80U) {
                return false;
            }
            codepoint = (codepoint << 6U) | (byte & 0x3fU);
        }
        const std::uint32_t minimum = width == 2 ? 0x80U : (width == 3 ? 0x800U : 0x10000U);
        if (codepoint < minimum || codepoint > 0x10ffffU ||
            (codepoint >= 0xd800U && codepoint <= 0xdfffU)) {
            return false;
        }
        index += width;
    }
    return true;
}

void append_utf8(std::string& output, std::uint32_t codepoint) {
    if (codepoint <= 0x7fU) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ffU) {
        output.push_back(static_cast<char>(0xc0U | (codepoint >> 6U)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else if (codepoint <= 0xffffU) {
        output.push_back(static_cast<char>(0xe0U | (codepoint >> 12U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else {
        output.push_back(static_cast<char>(0xf0U | (codepoint >> 18U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 12U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    }
}

class Parser {
public:
    Parser(std::string_view input, JsonLimits limits) : input_(input), limits_(limits) {}

    Result<Json> parse() {
        if (input_.size() > limits_.max_input_bytes) {
            return decode_error("JSON message exceeds max_input_bytes");
        }
        skip_space();
        auto value = parse_value(0);
        if (!value) {
            return std::move(value).error();
        }
        skip_space();
        if (position_ != input_.size()) {
            return fail("trailing characters");
        }
        return value;
    }

private:
    Result<Json> parse_value(std::size_t depth) {
        if (depth > limits_.max_depth) {
            return fail("maximum nesting depth exceeded");
        }
        if (++nodes_ > limits_.max_nodes) {
            return fail("maximum JSON node count exceeded");
        }
        if (position_ >= input_.size()) {
            return fail("unexpected end of input");
        }
        switch (input_[position_]) {
            case 'n':
                return literal("null", Json(nullptr));
            case 't':
                return literal("true", Json(true));
            case 'f':
                return literal("false", Json(false));
            case '"': {
                auto string = parse_string();
                if (!string) {
                    return std::move(string).error();
                }
                return Json(std::move(string).value());
            }
            case '[':
                return parse_array(depth + 1);
            case '{':
                return parse_object(depth + 1);
            default:
                if (input_[position_] == '-' ||
                    (input_[position_] >= '0' && input_[position_] <= '9')) {
                    return parse_number();
                }
                return fail("unexpected token");
        }
    }

    Result<Json> literal(std::string_view expected, Json value) {
        if (input_.substr(position_, expected.size()) != expected) {
            return fail("invalid literal");
        }
        position_ += expected.size();
        return value;
    }

    Result<std::string> parse_string() {
        if (input_[position_] != '"') {
            return fail_error<std::string>("expected a string");
        }
        ++position_;
        std::string output;
        while (position_ < input_.size()) {
            const char ch = input_[position_++];
            if (ch == '"') {
                if (output.size() > limits_.max_string_bytes) {
                    return fail_error<std::string>("string exceeds max_string_bytes");
                }
                if (!valid_utf8(output)) {
                    return fail_error<std::string>("string is not valid UTF-8");
                }
                return output;
            }
            if (static_cast<unsigned char>(ch) < 0x20U) {
                return fail_error<std::string>("unescaped control character in string");
            }
            if (ch != '\\') {
                output.push_back(ch);
                if (output.size() > limits_.max_string_bytes) {
                    return fail_error<std::string>("string exceeds max_string_bytes");
                }
                continue;
            }
            if (position_ >= input_.size()) {
                return fail_error<std::string>("unterminated escape sequence");
            }
            const char escaped = input_[position_++];
            switch (escaped) {
                case '"':
                case '\\':
                case '/':
                    output.push_back(escaped);
                    break;
                case 'b':
                    output.push_back('\b');
                    break;
                case 'f':
                    output.push_back('\f');
                    break;
                case 'n':
                    output.push_back('\n');
                    break;
                case 'r':
                    output.push_back('\r');
                    break;
                case 't':
                    output.push_back('\t');
                    break;
                case 'u': {
                    auto first = parse_hex_quad();
                    if (!first) {
                        return std::move(first).error();
                    }
                    std::uint32_t codepoint = first.value();
                    if (codepoint >= 0xd800U && codepoint <= 0xdbffU) {
                        if (position_ + 2 > input_.size() || input_[position_] != '\\' ||
                            input_[position_ + 1] != 'u') {
                            return fail_error<std::string>(
                                "high surrogate is not followed by a low surrogate");
                        }
                        position_ += 2;
                        auto second = parse_hex_quad();
                        if (!second) {
                            return std::move(second).error();
                        }
                        if (second.value() < 0xdc00U || second.value() > 0xdfffU) {
                            return fail_error<std::string>("invalid low surrogate");
                        }
                        codepoint = 0x10000U + ((codepoint - 0xd800U) << 10U) +
                                    (second.value() - 0xdc00U);
                    } else if (codepoint >= 0xdc00U && codepoint <= 0xdfffU) {
                        return fail_error<std::string>("unexpected low surrogate");
                    }
                    append_utf8(output, codepoint);
                    break;
                }
                default:
                    return fail_error<std::string>("invalid escape sequence");
            }
        }
        return fail_error<std::string>("unterminated string");
    }

    Result<std::uint32_t> parse_hex_quad() {
        if (position_ + 4 > input_.size()) {
            return fail_error<std::uint32_t>("truncated Unicode escape");
        }
        std::uint32_t value = 0;
        for (int index = 0; index < 4; ++index) {
            const char ch = input_[position_++];
            value <<= 4U;
            if (ch >= '0' && ch <= '9') {
                value |= static_cast<std::uint32_t>(ch - '0');
            } else if (ch >= 'a' && ch <= 'f') {
                value |= static_cast<std::uint32_t>(ch - 'a' + 10);
            } else if (ch >= 'A' && ch <= 'F') {
                value |= static_cast<std::uint32_t>(ch - 'A' + 10);
            } else {
                return fail_error<std::uint32_t>("invalid Unicode escape");
            }
        }
        return value;
    }

    Result<Json> parse_array(std::size_t depth) {
        ++position_;
        skip_space();
        Json::Array values;
        if (consume(']')) {
            return Json(std::move(values));
        }
        while (true) {
            auto value = parse_value(depth);
            if (!value) {
                return std::move(value).error();
            }
            values.push_back(std::move(value).value());
            skip_space();
            if (consume(']')) {
                return Json(std::move(values));
            }
            if (!consume(',')) {
                return fail("expected ',' or ']'");
            }
            skip_space();
        }
    }

    Result<Json> parse_object(std::size_t depth) {
        ++position_;
        skip_space();
        Json::Object values;
        if (consume('}')) {
            return Json(std::move(values));
        }
        while (true) {
            if (position_ >= input_.size() || input_[position_] != '"') {
                return fail("object key must be a string");
            }
            auto key = parse_string();
            if (!key) {
                return std::move(key).error();
            }
            skip_space();
            if (!consume(':')) {
                return fail("expected ':' after object key");
            }
            skip_space();
            auto value = parse_value(depth);
            if (!value) {
                return std::move(value).error();
            }
            auto [_, inserted] = values.emplace(std::move(key).value(), std::move(value).value());
            if (!inserted) {
                return fail("duplicate object key");
            }
            skip_space();
            if (consume('}')) {
                return Json(std::move(values));
            }
            if (!consume(',')) {
                return fail("expected ',' or '}'");
            }
            skip_space();
        }
    }

    Result<Json> parse_number() {
        const std::size_t begin = position_;
        const bool negative = consume('-');
        if (position_ >= input_.size()) {
            return fail("truncated number");
        }
        if (consume('0')) {
            if (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
                return fail("leading zero in number");
            }
        } else {
            if (input_[position_] < '1' || input_[position_] > '9') {
                return fail("invalid number");
            }
            while (position_ < input_.size() && input_[position_] >= '0' &&
                   input_[position_] <= '9') {
                ++position_;
            }
        }
        bool floating = false;
        if (consume('.')) {
            floating = true;
            const auto fractional_begin = position_;
            while (position_ < input_.size() && input_[position_] >= '0' &&
                   input_[position_] <= '9') {
                ++position_;
            }
            if (fractional_begin == position_) {
                return fail("fractional part requires digits");
            }
        }
        if (position_ < input_.size() && (input_[position_] == 'e' || input_[position_] == 'E')) {
            floating = true;
            ++position_;
            if (position_ < input_.size() && (input_[position_] == '+' || input_[position_] == '-')) {
                ++position_;
            }
            const auto exponent_begin = position_;
            while (position_ < input_.size() && input_[position_] >= '0' &&
                   input_[position_] <= '9') {
                ++position_;
            }
            if (exponent_begin == position_) {
                return fail("exponent requires digits");
            }
        }
        const auto token = input_.substr(begin, position_ - begin);
        if (floating) {
            double value = 0.0;
            const auto result =
                std::from_chars(token.data(), token.data() + token.size(), value, std::chars_format::general);
            if (result.ec != std::errc{} || result.ptr != token.data() + token.size() ||
                !std::isfinite(value)) {
                return fail("floating-point number is out of range");
            }
            return Json(value);
        }
        if (negative) {
            std::int64_t value = 0;
            const auto result = std::from_chars(token.data(), token.data() + token.size(), value);
            if (result.ec != std::errc{} || result.ptr != token.data() + token.size()) {
                return fail("signed integer is out of range");
            }
            return Json(value);
        }
        std::uint64_t value = 0;
        const auto result = std::from_chars(token.data(), token.data() + token.size(), value);
        if (result.ec != std::errc{} || result.ptr != token.data() + token.size()) {
            return fail("unsigned integer is out of range");
        }
        return Json(value);
    }

    bool consume(char expected) {
        if (position_ < input_.size() && input_[position_] == expected) {
            ++position_;
            return true;
        }
        return false;
    }

    void skip_space() {
        while (position_ < input_.size()) {
            const char ch = input_[position_];
            if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') {
                break;
            }
            ++position_;
        }
    }

    template <typename T>
    Result<T> fail_error(std::string message) const {
        return decode_error(std::move(message) + " at byte " + std::to_string(position_));
    }

    Result<Json> fail(std::string message) const { return fail_error<Json>(std::move(message)); }

    std::string_view input_;
    JsonLimits limits_;
    std::size_t position_ = 0;
    std::size_t nodes_ = 0;
};

class Encoder {
public:
    explicit Encoder(JsonLimits limits) : limits_(limits) {}

    Result<std::string> encode(const Json& value) {
        auto encoded = append(value, 0);
        if (!encoded) {
            return std::move(encoded).error();
        }
        if (output_.size() > limits_.max_input_bytes) {
            return decode_error("encoded JSON exceeds max_input_bytes");
        }
        return std::move(output_);
    }

private:
    Result<void> append(const Json& json, std::size_t depth) {
        if (depth > limits_.max_depth) {
            return decode_error("maximum nesting depth exceeded while encoding");
        }
        if (++nodes_ > limits_.max_nodes) {
            return decode_error("maximum JSON node count exceeded while encoding");
        }
        return std::visit(
            [this, depth](const auto& value) -> Result<void> {
                using T = std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<T, std::nullptr_t>) {
                    output_ += "null";
                } else if constexpr (std::is_same_v<T, bool>) {
                    output_ += value ? "true" : "false";
                } else if constexpr (std::is_same_v<T, std::int64_t> ||
                                     std::is_same_v<T, std::uint64_t>) {
                    output_ += std::to_string(value);
                } else if constexpr (std::is_same_v<T, double>) {
                    if (!std::isfinite(value)) {
                        return decode_error("cannot encode non-finite number");
                    }
                    char buffer[64];
                    const auto result = std::to_chars(
                        std::begin(buffer), std::end(buffer), value, std::chars_format::general,
                        std::numeric_limits<double>::max_digits10);
                    if (result.ec != std::errc{}) {
                        return decode_error("failed to encode floating-point number");
                    }
                    output_.append(buffer, result.ptr);
                } else if constexpr (std::is_same_v<T, std::string>) {
                    return append_string(value);
                } else if constexpr (std::is_same_v<T, Json::Array>) {
                    output_.push_back('[');
                    bool first = true;
                    for (const auto& item : value) {
                        if (!first) {
                            output_.push_back(',');
                        }
                        first = false;
                        auto result = append(item, depth + 1);
                        if (!result) {
                            return result;
                        }
                    }
                    output_.push_back(']');
                } else {
                    output_.push_back('{');
                    bool first = true;
                    for (const auto& [key, item] : value) {
                        if (!first) {
                            output_.push_back(',');
                        }
                        first = false;
                        auto key_result = append_string(key);
                        if (!key_result) {
                            return key_result;
                        }
                        output_.push_back(':');
                        auto value_result = append(item, depth + 1);
                        if (!value_result) {
                            return value_result;
                        }
                    }
                    output_.push_back('}');
                }
                if (output_.size() > limits_.max_input_bytes) {
                    return decode_error("encoded JSON exceeds max_input_bytes");
                }
                return {};
            },
            json.value());
    }

    Result<void> append_string(std::string_view value) {
        if (value.size() > limits_.max_string_bytes) {
            return decode_error("string exceeds max_string_bytes");
        }
        if (!valid_utf8(value)) {
            return decode_error("cannot encode a string that is not valid UTF-8");
        }
        output_.push_back('"');
        constexpr char hex[] = "0123456789abcdef";
        for (const char raw_ch : value) {
            const auto ch = static_cast<unsigned char>(raw_ch);
            switch (ch) {
                case '"':
                    output_ += "\\\"";
                    break;
                case '\\':
                    output_ += "\\\\";
                    break;
                case '\b':
                    output_ += "\\b";
                    break;
                case '\f':
                    output_ += "\\f";
                    break;
                case '\n':
                    output_ += "\\n";
                    break;
                case '\r':
                    output_ += "\\r";
                    break;
                case '\t':
                    output_ += "\\t";
                    break;
                default:
                    if (ch < 0x20U) {
                        output_ += "\\u00";
                        output_.push_back(hex[ch >> 4U]);
                        output_.push_back(hex[ch & 0x0fU]);
                    } else {
                        output_.push_back(static_cast<char>(ch));
                    }
            }
        }
        output_.push_back('"');
        return {};
    }

    JsonLimits limits_;
    std::size_t nodes_ = 0;
    std::string output_;
};

template <typename T>
Result<T> type_error(std::string expected) {
    return decode_error("expected JSON " + std::move(expected));
}

}  // namespace

std::string Error::code_name() const {
    switch (code) {
        case ErrorCode::invalid_argument:
            return "invalid_argument";
        case ErrorCode::connection:
            return "connection";
        case ErrorCode::timeout:
            return "timeout";
        case ErrorCode::protocol:
            return "protocol";
        case ErrorCode::command:
            return "command";
        case ErrorCode::authority:
            return "authority";
        case ErrorCode::decode:
            return "decode";
        case ErrorCode::closed:
            return "closed";
        case ErrorCode::canceled:
            return "canceled";
        case ErrorCode::outcome_uncertain:
            return "outcome_uncertain";
        case ErrorCode::stream_local_overflow:
            return "stream.local_overflow";
        case ErrorCode::unsupported:
            return "unsupported";
    }
    return "unknown";
}

Result<Json> Json::parse(std::string_view input, JsonLimits limits) {
    return Parser(input, limits).parse();
}

Result<std::string> Json::encode(JsonLimits limits) const {
    return Encoder(limits).encode(*this);
}

bool Json::is_null() const noexcept { return std::holds_alternative<std::nullptr_t>(value_); }
bool Json::is_bool() const noexcept { return std::holds_alternative<bool>(value_); }
bool Json::is_integer() const noexcept {
    return std::holds_alternative<std::int64_t>(value_) ||
           std::holds_alternative<std::uint64_t>(value_);
}
bool Json::is_number() const noexcept { return is_integer() || std::holds_alternative<double>(value_); }
bool Json::is_string() const noexcept { return std::holds_alternative<std::string>(value_); }
bool Json::is_array() const noexcept { return std::holds_alternative<Array>(value_); }
bool Json::is_object() const noexcept { return std::holds_alternative<Object>(value_); }

Result<bool> Json::as_bool() const {
    if (const auto* value = std::get_if<bool>(&value_)) {
        return *value;
    }
    return type_error<bool>("boolean");
}

Result<std::int64_t> Json::as_int64() const {
    if (const auto* value = std::get_if<std::int64_t>(&value_)) {
        return *value;
    }
    if (const auto* value = std::get_if<std::uint64_t>(&value_);
        value && *value <= static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
        return static_cast<std::int64_t>(*value);
    }
    return type_error<std::int64_t>("signed integer");
}

Result<std::uint64_t> Json::as_uint64() const {
    if (const auto* value = std::get_if<std::uint64_t>(&value_)) {
        return *value;
    }
    if (const auto* value = std::get_if<std::int64_t>(&value_); value && *value >= 0) {
        return static_cast<std::uint64_t>(*value);
    }
    return type_error<std::uint64_t>("unsigned integer");
}

Result<double> Json::as_double() const {
    if (const auto* value = std::get_if<double>(&value_)) {
        return *value;
    }
    if (const auto* value = std::get_if<std::int64_t>(&value_)) {
        return static_cast<double>(*value);
    }
    if (const auto* value = std::get_if<std::uint64_t>(&value_)) {
        return static_cast<double>(*value);
    }
    return type_error<double>("number");
}

Result<std::string_view> Json::as_string() const {
    if (const auto* value = std::get_if<std::string>(&value_)) {
        return std::string_view(*value);
    }
    return type_error<std::string_view>("string");
}

Result<const Json::Array*> Json::as_array() const {
    if (const auto* value = std::get_if<Array>(&value_)) {
        return value;
    }
    return type_error<const Array*>("array");
}

Result<const Json::Object*> Json::as_object() const {
    if (const auto* value = std::get_if<Object>(&value_)) {
        return value;
    }
    return type_error<const Object*>("object");
}

Result<Json::Array*> Json::as_array() {
    if (auto* value = std::get_if<Array>(&value_)) {
        return value;
    }
    return type_error<Array*>("array");
}

Result<Json::Object*> Json::as_object() {
    if (auto* value = std::get_if<Object>(&value_)) {
        return value;
    }
    return type_error<Object*>("object");
}

const Json* Json::find(std::string_view key) const noexcept {
    const auto* object = std::get_if<Object>(&value_);
    if (!object) {
        return nullptr;
    }
    const auto found = object->find(key);
    return found == object->end() ? nullptr : &found->second;
}

Json* Json::find(std::string_view key) noexcept {
    auto* object = std::get_if<Object>(&value_);
    if (!object) {
        return nullptr;
    }
    const auto found = object->find(key);
    return found == object->end() ? nullptr : &found->second;
}

Result<const Json*> require_field(const Json& object, std::string_view name) {
    if (!object.is_object()) {
        return decode_error("expected JSON object while reading field '" + std::string(name) + "'");
    }
    if (const auto* value = object.find(name)) {
        return value;
    }
    return decode_error("missing required field '" + std::string(name) + "'");
}

Result<std::string> require_string(const Json& object, std::string_view name) {
    auto field = require_field(object, name);
    if (!field) {
        return std::move(field).error();
    }
    auto value = field.value()->as_string();
    if (!value) {
        return decode_error("field '" + std::string(name) + "' must be a string");
    }
    return std::string(value.value());
}

Result<std::uint64_t> require_uint64(const Json& object, std::string_view name) {
    auto field = require_field(object, name);
    if (!field) {
        return std::move(field).error();
    }
    auto value = field.value()->as_uint64();
    if (!value) {
        return decode_error("field '" + std::string(name) + "' must be an unsigned integer");
    }
    return value.value();
}

Result<std::int64_t> require_int64(const Json& object, std::string_view name) {
    auto field = require_field(object, name);
    if (!field) {
        return std::move(field).error();
    }
    auto value = field.value()->as_int64();
    if (!value) {
        return decode_error("field '" + std::string(name) + "' must be a signed integer");
    }
    return value.value();
}

Result<bool> require_bool(const Json& object, std::string_view name) {
    auto field = require_field(object, name);
    if (!field) {
        return std::move(field).error();
    }
    auto value = field.value()->as_bool();
    if (!value) {
        return decode_error("field '" + std::string(name) + "' must be a boolean");
    }
    return value.value();
}

}  // namespace cmux
