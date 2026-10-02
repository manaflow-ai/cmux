#pragma once

#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>

namespace cmux {

class Json;
struct MutationOutcomeUncertain;

enum class ErrorCode {
    invalid_argument,
    connection,
    timeout,
    protocol,
    command,
    decode,
    closed,
    canceled,
    outcome_uncertain,
    stream_local_overflow,
    unsupported,
    authority,
};

struct Error {
    ErrorCode code = ErrorCode::protocol;
    std::string message;
    std::shared_ptr<const Json> response;
    std::string protocol_code;
    std::shared_ptr<const Json> details;
    bool retryable = false;
    int system_errno = 0;
    std::shared_ptr<const MutationOutcomeUncertain> uncertain_mutation;

    [[nodiscard]] std::string code_name() const;
};

template <typename T>
class [[nodiscard]] Result {
public:
    Result(const T& value) : value_(value) {}
    Result(T&& value) : value_(std::move(value)) {}
    Result(const Error& error) : value_(error) {}
    Result(Error&& error) : value_(std::move(error)) {}

    [[nodiscard]] bool has_value() const noexcept {
        return std::holds_alternative<T>(value_);
    }

    explicit operator bool() const noexcept { return has_value(); }

    T& value() & {
        if (!has_value()) {
            throw std::logic_error("cmux::Result does not contain a value");
        }
        return std::get<T>(value_);
    }

    const T& value() const& {
        if (!has_value()) {
            throw std::logic_error("cmux::Result does not contain a value");
        }
        return std::get<T>(value_);
    }

    T&& value() && {
        if (!has_value()) {
            throw std::logic_error("cmux::Result does not contain a value");
        }
        return std::get<T>(std::move(value_));
    }

    Error& error() & {
        if (has_value()) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return std::get<Error>(value_);
    }

    const Error& error() const& {
        if (has_value()) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return std::get<Error>(value_);
    }

    Error&& error() && {
        if (has_value()) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return std::get<Error>(std::move(value_));
    }

private:
    std::variant<T, Error> value_;
};

template <>
class [[nodiscard]] Result<void> {
public:
    Result() = default;
    Result(const Error& error) : error_(error) {}
    Result(Error&& error) : error_(std::move(error)) {}

    [[nodiscard]] bool has_value() const noexcept { return !error_; }
    explicit operator bool() const noexcept { return has_value(); }

    void value() const {
        if (error_) {
            throw std::logic_error("cmux::Result does not contain a value");
        }
    }

    Error& error() & {
        if (!error_) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return *error_;
    }

    const Error& error() const& {
        if (!error_) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return *error_;
    }

    Error&& error() && {
        if (!error_) {
            throw std::logic_error("cmux::Result does not contain an error");
        }
        return std::move(*error_);
    }

private:
    std::optional<Error> error_;
};

inline Error make_error(ErrorCode code, std::string message) {
    Error error;
    error.code = code;
    error.message = std::move(message);
    return error;
}

}  // namespace cmux
