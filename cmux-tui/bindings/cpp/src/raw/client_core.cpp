#include "cmux/raw/client_core.hpp"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <utility>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

#include "cmux/raw/generated/commands.hpp"
#include "socket_path_internal.hpp"

namespace cmux::raw {
namespace detail {
namespace {

using Clock = std::chrono::steady_clock;

[[nodiscard]] Timeout remaining(Clock::time_point deadline) {
    const auto now = Clock::now();
    if (now >= deadline) {
        return Timeout(0);
    }
    return std::max(
        Timeout(1), std::chrono::duration_cast<Timeout>(deadline - now));
}

[[nodiscard]] bool same_request_id(const Json& left, const Json& right) {
    if (left.is_integer() && right.is_integer()) {
        auto left_id = left.as_uint64();
        auto right_id = right.as_uint64();
        return left_id && right_id && left_id.value() == right_id.value();
    }
    return left == right;
}

[[nodiscard]] Result<Json> successful_response(const Json& response) {
    auto object = response.as_object();
    if (!object) {
        return make_error(ErrorCode::protocol, "server response must be a JSON object");
    }
    const Json* ok = response.find("ok");
    if (!ok) {
        return make_error(ErrorCode::protocol, "server response is missing 'ok'");
    }
    auto succeeded = ok->as_bool();
    if (!succeeded) {
        return make_error(ErrorCode::protocol, "server response 'ok' must be a boolean");
    }
    if (succeeded.value()) {
        if (const Json* data = response.find("data")) {
            return *data;
        }
        return Json(Json::Object{});
    }
    std::string message = "cmux-tui command failed";
    if (const Json* error = response.find("error")) {
        if (auto text = error->as_string()) {
            message = std::string(text.value());
        }
    }
    Error result = make_error(ErrorCode::command, std::move(message));
    result.response = std::make_shared<Json>(response);
    return result;
}

[[nodiscard]] const CommandMetadata* find_command_metadata(
    std::string_view command) noexcept {
    const auto commands = command_metadata();
    const auto metadata = std::find_if(
        commands.begin(), commands.end(),
        [&](const auto& entry) { return entry.name == command; });
    return metadata == commands.end() ? nullptr : &*metadata;
}

[[nodiscard]] Result<void> require_authority(
    const ClientOptions& options,
    std::string_view command,
    const CommandMetadata* metadata) {
    if (!metadata || options.authorities.allows(metadata->authority)) {
        return {};
    }
    return make_error(
        ErrorCode::authority,
        "command '" + std::string(command) + "' requires " +
            std::string(metadata->authority) +
            "; enable it in ClientOptions.authorities before connecting");
}

struct NegotiatedServer {
    std::uint32_t protocol = 0;
    std::vector<std::string> capabilities;

    [[nodiscard]] bool has_capability(std::string_view capability) const noexcept {
        return std::find(capabilities.begin(), capabilities.end(), capability) !=
               capabilities.end();
    }
};

[[nodiscard]] Result<void> require_compatibility(
    const NegotiatedServer& server,
    const CommandMetadata& metadata,
    const Json::Object& parameters) {
    if (metadata.since > server.protocol) {
        return make_error(
            ErrorCode::unsupported,
            "command '" + std::string(metadata.name) + "' requires protocol " +
                std::to_string(metadata.since) + "; server uses protocol " +
                std::to_string(server.protocol));
    }
    if (!metadata.capability.empty() &&
        !server.has_capability(metadata.capability)) {
        return make_error(
            ErrorCode::unsupported,
            "command '" + std::string(metadata.name) + "' requires capability '" +
                std::string(metadata.capability) + "'");
    }
    for (const auto& field : metadata.field_requirements) {
        if (!parameters.contains(field.name)) {
            continue;
        }
        const std::string qualified =
            std::string(metadata.name) + "." + std::string(field.name);
        if (field.since != 0 && field.since > server.protocol) {
            return make_error(
                ErrorCode::unsupported,
                "command field '" + qualified + "' requires protocol " +
                    std::to_string(field.since) + "; server uses protocol " +
                    std::to_string(server.protocol));
        }
        if (!field.capability.empty() &&
            !server.has_capability(field.capability)) {
            return make_error(
                ErrorCode::unsupported,
                "command field '" + qualified + "' requires capability '" +
                    std::string(field.capability) + "'");
        }
    }
    return {};
}

}  // namespace

struct ClientCore::Impl {
    ClientOptions options;
    std::unique_ptr<Transport> control;
    TransportFactory stream_factory;
    std::mutex request_mutex;
    std::atomic<std::uint64_t> next_request_id{1};
    std::atomic<bool> closed{false};
    std::optional<NegotiatedServer> negotiated_server;

    [[nodiscard]] Result<Json> request_locked(
        std::string_view command,
        Json::Object parameters,
        Clock::time_point deadline);
    [[nodiscard]] Result<void> remember_server(const Json& identify_result);
    [[nodiscard]] Result<void> ensure_negotiated_locked(Clock::time_point deadline);
};

Result<Json> ClientCore::Impl::request_locked(
    std::string_view command,
    Json::Object parameters,
    Clock::time_point deadline) {
    if (closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (Clock::now() >= deadline) {
        return make_error(ErrorCode::timeout, "command response timed out");
    }

    const auto request_id = next_request_id.fetch_add(1, std::memory_order_relaxed);
    parameters.emplace("id", Json(request_id));
    parameters.emplace("cmd", Json(std::string(command)));
    auto encoded = Json(std::move(parameters)).encode(options.json_limits);
    if (!encoded) {
        return std::move(encoded).error();
    }

    auto sent = control->send(encoded.value(), remaining(deadline));
    if (!sent) {
        return std::move(sent).error();
    }

    const Json expected_id(request_id);
    while (true) {
        if (Clock::now() >= deadline) {
            return make_error(ErrorCode::timeout, "command response timed out");
        }
        auto wire = control->receive(remaining(deadline));
        if (!wire) {
            return std::move(wire).error();
        }
        auto response = Json::parse(wire.value(), options.json_limits);
        if (!response) {
            return std::move(response).error();
        }
        if (!response.value().is_object()) {
            return make_error(ErrorCode::protocol, "server message must be a JSON object");
        }
        if (response.value().find("event")) {
            continue;
        }
        if (const Json* id = response.value().find("id");
            id && !same_request_id(*id, expected_id)) {
            continue;
        }
        return successful_response(response.value());
    }
}

Result<void> ClientCore::Impl::remember_server(const Json& identify_result) {
    auto object = identify_result.as_object();
    if (!object) {
        return std::move(object).error();
    }
    const Json* protocol_field = identify_result.find("protocol");
    if (!protocol_field) {
        return make_error(
            ErrorCode::decode, "identify response is missing required field 'protocol'");
    }
    auto protocol = decode_value<std::uint32_t>(*protocol_field);
    if (!protocol) {
        return std::move(protocol).error();
    }
    NegotiatedServer server;
    server.protocol = protocol.value();
    if (const Json* capabilities = identify_result.find("capabilities")) {
        auto decoded = decode_value<std::vector<std::string>>(*capabilities);
        if (!decoded) {
            return std::move(decoded).error();
        }
        server.capabilities = std::move(decoded).value();
    }
    negotiated_server = std::move(server);
    return {};
}

Result<void> ClientCore::Impl::ensure_negotiated_locked(Clock::time_point deadline) {
    if (negotiated_server) {
        return {};
    }
    auto identified = request_locked("identify", {}, deadline);
    if (!identified) {
        return std::move(identified).error();
    }
    return remember_server(identified.value());
}

ClientCore::ClientCore(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}
ClientCore::~ClientCore() { close(); }

Result<ClientCore> ClientCore::connect(ClientOptions options) {
    if (options.timeout <= Timeout::zero()) {
        return make_error(ErrorCode::invalid_argument, "client timeout must be positive");
    }
    if (options.max_buffered_stream_events == 0) {
        return make_error(
            ErrorCode::invalid_argument, "max_buffered_stream_events must be positive");
    }

    TransportFactory control_factory = options.transport_factory;
    if (!control_factory) {
        auto path = resolve_socket_path(
            options.socket_path, options.session);
        if (!path) {
            return std::move(path).error();
        }
        auto resolved_path = std::move(path).value();
        const bool implicit_path = options.socket_path.empty() && socket_path_from_environment().empty();
        const bool hashed_path = ::cmux::detail::is_hashed_socket_path_for_uid(
            resolved_path, static_cast<unsigned long>(::getuid()));
        std::string legacy_path;
        if (implicit_path && hashed_path) {
            legacy_path = "/tmp/cmux-tui-" +
                std::to_string(static_cast<unsigned long>(::getuid())) + "/" +
                options.session + ".sock";
            if (legacy_path.size() >= sizeof(sockaddr_un{}.sun_path)) {
                legacy_path.clear();
            }
        }
        auto effective_path = std::make_shared<std::string>(resolved_path);
        const bool has_legacy_path = !legacy_path.empty();
        control_factory = [effective_path, legacy_path = std::move(legacy_path), timeout = options.timeout,
                           limits = options.transport_limits]() mutable -> Result<std::unique_ptr<Transport>> {
            auto first = UnixTransport::connect(*effective_path, timeout, limits);
            if (first || legacy_path.empty() ||
                (first.error().system_errno != ENOENT &&
                 first.error().system_errno != ECONNREFUSED)) {
                return first;
            }
            auto fallback = UnixTransport::connect(legacy_path, timeout, limits);
            if (fallback) {
                *effective_path = legacy_path;
            }
            return fallback;
        };
        options.socket_path = resolved_path;
        if (!has_legacy_path) {
            control_factory = unix_transport_factory(
                std::move(resolved_path), options.timeout, options.transport_limits);
        }
        if (has_legacy_path && !options.stream_transport_factory) {
            auto stream_path = effective_path;
            options.stream_transport_factory = [stream_path, timeout = options.timeout,
                                                limits = options.transport_limits]() {
                return UnixTransport::connect(*stream_path, timeout, limits);
            };
        }
    }
    TransportFactory stream_factory = options.stream_transport_factory;
    if (!stream_factory) {
        stream_factory = control_factory;
    }
    auto transport = control_factory();
    if (!transport) {
        return std::move(transport).error();
    }

    auto impl = std::make_shared<Impl>();
    impl->options = std::move(options);
    impl->control = std::move(transport).value();
    impl->stream_factory = std::move(stream_factory);
    return ClientCore(std::move(impl));
}

Result<Json> ClientCore::request(
    std::string_view command,
    Json::Object parameters,
    std::optional<Timeout> timeout) {
    if (!impl_ || impl_->closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (command.empty()) {
        return make_error(ErrorCode::invalid_argument, "command cannot be empty");
    }
    if (parameters.contains("cmd") || parameters.contains("id")) {
        return make_error(
            ErrorCode::invalid_argument, "typed request parameters cannot contain 'cmd' or 'id'");
    }
    const CommandMetadata* metadata = find_command_metadata(command);
    auto authorized = require_authority(impl_->options, command, metadata);
    if (!authorized) {
        return std::move(authorized).error();
    }
    const Timeout operation_timeout = timeout.value_or(impl_->options.timeout);
    if (operation_timeout <= Timeout::zero()) {
        return make_error(ErrorCode::invalid_argument, "request timeout must be positive");
    }
    const auto deadline = Clock::now() + operation_timeout;
    std::lock_guard lock(impl_->request_mutex);
    if (impl_->closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (metadata && command != "identify") {
        auto negotiated = impl_->ensure_negotiated_locked(deadline);
        if (!negotiated) {
            return std::move(negotiated).error();
        }
        auto compatible = require_compatibility(
            *impl_->negotiated_server, *metadata, parameters);
        if (!compatible) {
            return std::move(compatible).error();
        }
    }
    auto response = impl_->request_locked(command, std::move(parameters), deadline);
    if (response && command == "identify") {
        auto remembered = impl_->remember_server(response.value());
        if (!remembered) {
            impl_->negotiated_server.reset();
        }
    }
    return response;
}

Result<JsonStream> ClientCore::open_stream(
    std::string_view command,
    Json::Object parameters,
    std::string terminal_event,
    std::optional<Timeout> timeout) {
    if (!impl_ || impl_->closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (command.empty()) {
        return make_error(ErrorCode::invalid_argument, "command cannot be empty");
    }
    if (parameters.contains("cmd") || parameters.contains("id")) {
        return make_error(
            ErrorCode::invalid_argument, "typed request parameters cannot contain 'cmd' or 'id'");
    }
    const CommandMetadata* metadata = find_command_metadata(command);
    auto authorized = require_authority(impl_->options, command, metadata);
    if (!authorized) {
        return std::move(authorized).error();
    }
    const Timeout operation_timeout = timeout.value_or(impl_->options.timeout);
    if (operation_timeout <= Timeout::zero()) {
        return make_error(ErrorCode::invalid_argument, "stream timeout must be positive");
    }
    const auto deadline = Clock::now() + operation_timeout;
    if (metadata && command != "identify") {
        std::lock_guard lock(impl_->request_mutex);
        if (impl_->closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "client is closed");
        }
        auto negotiated = impl_->ensure_negotiated_locked(deadline);
        if (!negotiated) {
            return std::move(negotiated).error();
        }
        auto compatible = require_compatibility(
            *impl_->negotiated_server, *metadata, parameters);
        if (!compatible) {
            return std::move(compatible).error();
        }
    }
    if (impl_->closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (Clock::now() >= deadline) {
        return make_error(ErrorCode::timeout, "stream open response timed out");
    }
    auto transport = impl_->stream_factory();
    if (!transport) {
        return std::move(transport).error();
    }

    const auto request_id = impl_->next_request_id.fetch_add(1, std::memory_order_relaxed);
    parameters.emplace("id", Json(request_id));
    parameters.emplace("cmd", Json(std::string(command)));
    auto encoded = Json(std::move(parameters)).encode(impl_->options.json_limits);
    if (!encoded) {
        transport.value()->close();
        return std::move(encoded).error();
    }
    auto sent = transport.value()->send(encoded.value(), remaining(deadline));
    if (!sent) {
        transport.value()->close();
        return std::move(sent).error();
    }

    auto state = std::make_shared<StreamState>(
        std::move(transport).value(), impl_->options.max_buffered_stream_events,
        std::move(terminal_event));
    const Json expected_id(request_id);
    while (true) {
        if (Clock::now() >= deadline) {
            state->transport->close();
            return make_error(ErrorCode::timeout, "stream open response timed out");
        }
        auto wire = state->transport->receive(remaining(deadline));
        if (!wire) {
            state->transport->close();
            return std::move(wire).error();
        }
        auto message = Json::parse(wire.value(), impl_->options.json_limits);
        if (!message) {
            state->transport->close();
            return std::move(message).error();
        }
        if (!message.value().is_object()) {
            state->transport->close();
            return make_error(ErrorCode::protocol, "server stream message must be a JSON object");
        }
        if (message.value().find("event")) {
            if (state->buffered.size() >= state->max_buffered_events) {
                state->transport->close();
                return make_error(
                    ErrorCode::protocol, "stream produced too many events before its open response");
            }
            state->buffered.push_back(std::move(message).value());
            continue;
        }
        if (const Json* id = message.value().find("id");
            id && !same_request_id(*id, expected_id)) {
            continue;
        }
        auto response = successful_response(message.value());
        if (!response) {
            state->transport->close();
            return std::move(response).error();
        }
        break;
    }

    return JsonStream(
        std::move(state),
        [](const Json& event) -> Result<Json> {
            if (!event.is_object() || !event.find("event")) {
                return make_error(ErrorCode::protocol, "stream message is not an event");
            }
            return event;
        },
        {},
        operation_timeout);
}

void ClientCore::close() noexcept {
    if (!impl_) {
        return;
    }
    bool expected = false;
    if (impl_->closed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        impl_->control->close();
    }
}

bool ClientCore::closed() const noexcept {
    return !impl_ || impl_->closed.load(std::memory_order_acquire);
}

const ClientOptions& ClientCore::options() const noexcept {
    static const ClientOptions empty{};
    return impl_ ? impl_->options : empty;
}

}  // namespace detail
}  // namespace cmux::raw
