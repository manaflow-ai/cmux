#pragma once

#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

#include "cmux/json.hpp"
#include "cmux/transport.hpp"

namespace cmux::raw {
namespace detail {

struct StreamState {
    explicit StreamState(
        std::unique_ptr<Transport> value,
        std::size_t max_events,
        std::string terminal)
        : transport(std::move(value)),
          max_buffered_events(max_events),
          terminal_event(std::move(terminal)) {}

    std::unique_ptr<Transport> transport;
    std::deque<Json> buffered;
    std::mutex read_mutex;
    std::atomic<bool> closed{false};
    std::atomic<bool> terminal_seen{false};
    std::size_t max_buffered_events;
    std::string terminal_event;
};

}  // namespace detail

template <typename T>
class Stream {
public:
    using Decoder = std::function<Result<T>(const Json&)>;
    using TerminalPredicate = std::function<bool(const T&)>;

    Stream() = default;
    Stream(
        std::shared_ptr<detail::StreamState> state,
        Decoder decoder,
        TerminalPredicate terminal,
        Timeout default_timeout)
        : state_(std::move(state)),
          decoder_(std::move(decoder)),
          terminal_(std::move(terminal)),
          default_timeout_(default_timeout) {}

    Stream(const Stream&) = delete;
    Stream& operator=(const Stream&) = delete;
    Stream(Stream&&) noexcept = default;
    Stream& operator=(Stream&&) noexcept = default;

    ~Stream() { close(); }

    // Request and stream-open deadlines do not end an acknowledged idle stream.
    [[nodiscard]] Result<T> next() {
        while (true) {
            auto event = next(default_timeout_);
            if (event || event.error().code != ErrorCode::timeout) {
                return event;
            }
        }
    }

    // Bounds one wait without closing the stream when the wait times out.
    [[nodiscard]] Result<T> next(Timeout timeout) {
        if (!state_) {
            return make_error(ErrorCode::closed, "stream is not initialized");
        }
        if (state_->terminal_seen.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "stream has ended");
        }

        std::lock_guard read_lock(state_->read_mutex);
        if (state_->terminal_seen.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "stream has ended");
        }

        Json message;
        if (!state_->buffered.empty()) {
            message = std::move(state_->buffered.front());
            state_->buffered.pop_front();
        } else {
            if (state_->closed.load(std::memory_order_acquire)) {
                return make_error(ErrorCode::closed, "stream is closed");
            }
            auto wire = state_->transport->receive(timeout);
            if (!wire) {
                return std::move(wire).error();
            }
            auto parsed = Json::parse(wire.value());
            if (!parsed) {
                return std::move(parsed).error();
            }
            message = std::move(parsed).value();
        }

        bool is_terminal = false;
        if (!state_->terminal_event.empty()) {
            if (const Json* name = message.find("event")) {
                auto text = name->as_string();
                is_terminal = text && text.value() == state_->terminal_event;
            }
        }

        auto decoded = decoder_(message);
        if (!decoded) {
            return std::move(decoded).error();
        }
        if (is_terminal || (terminal_ && terminal_(decoded.value()))) {
            state_->terminal_seen.store(true, std::memory_order_release);
            state_->closed.store(true, std::memory_order_release);
            state_->transport->close();
        }
        return decoded;
    }

    void close() noexcept {
        if (!state_) {
            return;
        }
        bool expected = false;
        if (state_->closed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            state_->transport->close();
        }
    }

    [[nodiscard]] bool closed() const noexcept {
        return !state_ || state_->closed.load(std::memory_order_acquire);
    }

    template <typename U>
    [[nodiscard]] Stream<U> map(
        typename Stream<U>::Decoder decoder,
        typename Stream<U>::TerminalPredicate terminal = {}) && {
        auto state = std::move(state_);
        decoder_ = {};
        terminal_ = {};
        return Stream<U>(
            std::move(state), std::move(decoder), std::move(terminal), default_timeout_);
    }

private:
    template <typename>
    friend class Stream;

    std::shared_ptr<detail::StreamState> state_;
    Decoder decoder_;
    TerminalPredicate terminal_;
    Timeout default_timeout_{std::chrono::seconds(10)};
};

using JsonStream = Stream<Json>;

}  // namespace cmux::raw
