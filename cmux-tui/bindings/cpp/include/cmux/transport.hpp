#pragma once

#include <chrono>
#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

#include "cmux/result.hpp"

namespace cmux {

using Timeout = std::chrono::milliseconds;

struct TransportLimits {
    std::size_t max_message_bytes = 16U * 1024U * 1024U;
};

// A message transport. WebSocket integrations implement this interface and
// keep TLS, event-loop, and authentication choices in the host application.
// One send and one receive may run concurrently on the same instance.
class Transport {
public:
    virtual ~Transport() = default;
    [[nodiscard]] virtual Result<void> send(std::string_view message, Timeout timeout) = 0;
    [[nodiscard]] virtual Result<std::string> receive(Timeout timeout) = 0;
    virtual void close() noexcept = 0;
};

using TransportFactory = std::function<Result<std::unique_ptr<Transport>>()>;

class UnixTransport final : public Transport {
public:
    UnixTransport(const UnixTransport&) = delete;
    UnixTransport& operator=(const UnixTransport&) = delete;
    UnixTransport(UnixTransport&&) noexcept;
    UnixTransport& operator=(UnixTransport&&) noexcept;
    ~UnixTransport() override;

    [[nodiscard]] static Result<std::unique_ptr<Transport>> connect(
        std::string path,
        Timeout timeout,
        TransportLimits limits = {});

    [[nodiscard]] Result<void> send(std::string_view message, Timeout timeout) override;
    [[nodiscard]] Result<std::string> receive(Timeout timeout) override;
    void close() noexcept override;

#if defined(CMUX_CPP_TESTING)
    void set_before_receive_wait_for_testing(std::function<void()> hook);
#endif

private:
    struct Impl;
    explicit UnixTransport(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] std::string default_socket_path(std::string_view session = "main");
[[nodiscard]] std::string socket_path_from_environment();
[[nodiscard]] Result<std::string> resolve_socket_path(
    std::string_view explicit_path,
    std::string_view session = "main");
[[nodiscard]] TransportFactory unix_transport_factory(
    std::string path,
    Timeout connect_timeout,
    TransportLimits limits = {});

}  // namespace cmux
