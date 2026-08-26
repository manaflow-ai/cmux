#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "cmux/json.hpp"
#include "cmux/raw/stream.hpp"
#include "cmux/transport.hpp"

namespace cmux::raw {

struct RequestOptions {
    std::optional<Timeout> timeout;
};

struct ClientAuthorityPolicy {
    bool control = true;
    bool frontend = true;
    bool local_admin = true;
    bool provider_authority = false;

    [[nodiscard]] bool allows(std::string_view authority) const noexcept {
        if (authority == "control") {
            return control;
        }
        if (authority == "frontend") {
            return frontend;
        }
        if (authority == "local-admin") {
            return local_admin;
        }
        if (authority == "provider-authority") {
            return provider_authority;
        }
        return false;
    }
};

struct ClientOptions {
    std::string session{"main"};
    std::string socket_path;
    Timeout timeout{std::chrono::seconds(10)};
    TransportLimits transport_limits{};
    JsonLimits json_limits{};
    std::size_t max_buffered_stream_events{256};
    TransportFactory transport_factory;
    TransportFactory stream_transport_factory;
    ClientAuthorityPolicy authorities{};
};

namespace detail {

class ClientCore {
public:
    ClientCore() = default;
    ClientCore(const ClientCore&) = delete;
    ClientCore& operator=(const ClientCore&) = delete;
    ClientCore(ClientCore&&) noexcept = default;
    ClientCore& operator=(ClientCore&&) noexcept = default;
    ~ClientCore();

    [[nodiscard]] static Result<ClientCore> connect(ClientOptions options = {});

    [[nodiscard]] Result<Json> request(
        std::string_view command,
        Json::Object parameters = {},
        std::optional<Timeout> timeout = std::nullopt);

    [[nodiscard]] Result<JsonStream> open_stream(
        std::string_view command,
        Json::Object parameters = {},
        std::string terminal_event = {},
        std::optional<Timeout> timeout = std::nullopt);

    void close() noexcept;
    [[nodiscard]] bool closed() const noexcept;
    [[nodiscard]] const ClientOptions& options() const noexcept;

private:
    struct Impl;
    explicit ClientCore(std::shared_ptr<Impl> impl);
    std::shared_ptr<Impl> impl_;
};

template <typename T>
[[nodiscard]] Result<T> decode_as(const Json& value);

template <>
inline Result<Json> decode_as<Json>(const Json& value) {
    return value;
}

}  // namespace detail
}  // namespace cmux::raw
