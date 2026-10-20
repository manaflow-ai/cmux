#pragma once

#include <optional>
#include <stdexcept>
#include <utility>

namespace cmux::raw {

// Represents a wire field with three distinct states: omitted, explicit null,
// and a concrete value.
template <typename T>
class Field {
public:
    enum class State { absent, null, value };

    Field() = default;
    Field(const T& value) : state_(State::value), value_(value) {}
    Field(T&& value) : state_(State::value), value_(std::move(value)) {}

    [[nodiscard]] static Field null() {
        Field result;
        result.state_ = State::null;
        return result;
    }

    [[nodiscard]] static Field absent() { return {}; }

    [[nodiscard]] State state() const noexcept { return state_; }
    [[nodiscard]] bool is_absent() const noexcept { return state_ == State::absent; }
    [[nodiscard]] bool is_null() const noexcept { return state_ == State::null; }
    [[nodiscard]] bool has_value() const noexcept { return state_ == State::value; }

    T& value() & {
        if (!value_) {
            throw std::logic_error("cmux::Field does not contain a value");
        }
        return *value_;
    }

    const T& value() const& {
        if (!value_) {
            throw std::logic_error("cmux::Field does not contain a value");
        }
        return *value_;
    }

    T&& value() && {
        if (!value_) {
            throw std::logic_error("cmux::Field does not contain a value");
        }
        return std::move(*value_);
    }

    friend bool operator==(const Field&, const Field&) = default;

private:
    State state_ = State::absent;
    std::optional<T> value_;
};

}  // namespace cmux::raw
