#include "cmux/raw/attachment.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <sys/un.h>
#include <unistd.h>

#include "socket_path_internal.hpp"

namespace cmux::raw {
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

[[nodiscard]] bool same_request_id(const Json& value, std::uint64_t expected) {
    auto request_id = value.as_uint64();
    return request_id && request_id.value() == expected;
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

[[nodiscard]] Result<std::unique_ptr<Transport>> connect_transport(
    ClientOptions& options) {
    if (options.timeout <= Timeout::zero()) {
        return make_error(ErrorCode::invalid_argument, "attachment timeout must be positive");
    }
    if (options.max_buffered_stream_events == 0) {
        return make_error(
            ErrorCode::invalid_argument, "max_buffered_stream_events must be positive");
    }

    TransportFactory factory = options.stream_transport_factory;
    if (!factory) {
        factory = options.transport_factory;
    }
    if (!factory) {
        auto path = resolve_socket_path(
            options.socket_path, options.session);
        if (!path) {
            return std::move(path).error();
        }
        auto resolved_path = std::move(path).value();
        const bool implicit_path = options.socket_path.empty() &&
            socket_path_from_environment().empty();
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
        options.socket_path = resolved_path;
        const bool has_legacy_path = !legacy_path.empty();
        factory = [effective_path, legacy_path = std::move(legacy_path),
                   timeout = options.timeout, limits = options.transport_limits]() mutable {
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
        // Attachments may reconnect their stream. Keep using the path that
        // actually succeeded, including the legacy fallback.
        if (has_legacy_path) {
            options.stream_transport_factory = [effective_path,
                                                timeout = options.timeout,
                                                limits = options.transport_limits]() {
                return UnixTransport::connect(*effective_path, timeout, limits);
            };
        }
    }
    return factory();
}

struct Bootstrap {
    Transport& transport;
    const ClientOptions& options;
    std::deque<Event>& buffered_events;
    std::uint64_t next_request_id = 1;

    [[nodiscard]] Result<Json> request(
        std::string_view command,
        Json::Object parameters,
        Timeout timeout) {
        if (timeout <= Timeout::zero()) {
            return make_error(ErrorCode::invalid_argument, "request timeout must be positive");
        }
        const std::uint64_t request_id = next_request_id++;
        parameters.emplace("id", Json(request_id));
        parameters.emplace("cmd", Json(std::string(command)));
        auto encoded = Json(std::move(parameters)).encode(options.json_limits);
        if (!encoded) {
            return std::move(encoded).error();
        }

        const auto deadline = Clock::now() + timeout;
        auto sent = transport.send(encoded.value(), remaining(deadline));
        if (!sent) {
            return std::move(sent).error();
        }

        while (true) {
            if (Clock::now() >= deadline) {
                return make_error(ErrorCode::timeout, "attachment command response timed out");
            }
            auto wire = transport.receive(remaining(deadline));
            if (!wire) {
                return std::move(wire).error();
            }
            auto message = Json::parse(wire.value(), options.json_limits);
            if (!message) {
                return std::move(message).error();
            }
            if (!message.value().is_object()) {
                return make_error(
                    ErrorCode::protocol, "server attachment message must be a JSON object");
            }
            if (message.value().find("event")) {
                if (buffered_events.size() >= options.max_buffered_stream_events) {
                    return make_error(
                        ErrorCode::protocol, "attachment event buffer limit exceeded");
                }
                auto event = decode_value<Event>(message.value());
                if (!event) {
                    return std::move(event).error();
                }
                buffered_events.push_back(std::move(event).value());
                continue;
            }
            if (const Json* id = message.value().find("id");
                id && !same_request_id(*id, request_id)) {
                continue;
            }
            return successful_response(message.value());
        }
    }
};

[[nodiscard]] Result<std::uint64_t> self_client_id(const Json& response) {
    auto clients = decode_value<ListClientsResult>(response);
    if (!clients) {
        return std::move(clients).error();
    }
    std::optional<std::uint64_t> result;
    for (const auto& client : clients.value().value) {
        if (!client.self) {
            continue;
        }
        if (result) {
            return make_error(
                ErrorCode::protocol, "list-clients returned multiple self clients");
        }
        result = client.client;
    }
    if (!result) {
        return make_error(
            ErrorCode::protocol, "list-clients did not identify this connection");
    }
    return *result;
}

}  // namespace

struct SurfaceAttachment::Impl {
    struct PendingResponse {
        std::uint64_t id;
        std::optional<Result<Json>> result;
    };

    Impl(
        std::unique_ptr<Transport> transport_value,
        ClientOptions options_value,
        Id surface_value,
        std::uint64_t client_id_value,
        std::deque<Event> initial_events,
        std::uint64_t next_request_id_value)
        : transport(std::move(transport_value)),
          options(std::move(options_value)),
          surface(surface_value),
          client_id(client_id_value),
          events(std::move(initial_events)),
          next_request_id(next_request_id_value) {}

    ~Impl() { shutdown(); }

    Impl(const Impl&) = delete;
    Impl& operator=(const Impl&) = delete;

    void start_reader() {
        reader = std::thread([this] { read_messages(); });
    }

    [[nodiscard]] Result<Json> request(
        std::string_view command,
        Json::Object parameters,
        std::optional<Timeout> requested_timeout) {
        std::unique_lock command_lock(command_mutex);
        if (closed.load(std::memory_order_acquire)) {
            return closed_error();
        }
        const Timeout operation_timeout = requested_timeout.value_or(options.timeout);
        if (operation_timeout <= Timeout::zero()) {
            return make_error(ErrorCode::invalid_argument, "request timeout must be positive");
        }
        if (parameters.contains("cmd") || parameters.contains("id")) {
            return make_error(
                ErrorCode::invalid_argument,
                "typed request parameters cannot contain 'cmd' or 'id'");
        }

        const std::uint64_t request_id =
            next_request_id.fetch_add(1, std::memory_order_relaxed);
        parameters.emplace("id", Json(request_id));
        parameters.emplace("cmd", Json(std::string(command)));
        auto encoded = Json(std::move(parameters)).encode(options.json_limits);
        if (!encoded) {
            return std::move(encoded).error();
        }

        const auto deadline = Clock::now() + operation_timeout;
        {
            std::lock_guard state_lock(state_mutex);
            if (closed.load(std::memory_order_acquire)) {
                return closed_error_locked();
            }
            pending.emplace(PendingResponse{request_id, std::nullopt});
        }

        auto sent = transport->send(encoded.value(), remaining(deadline));
        if (!sent) {
            std::lock_guard state_lock(state_mutex);
            if (pending && pending->id == request_id) {
                pending.reset();
            }
            return std::move(sent).error();
        }

        std::unique_lock state_lock(state_mutex);
        const bool completed = state_changed.wait_until(state_lock, deadline, [&] {
            return closed.load(std::memory_order_acquire) ||
                   (pending && pending->id == request_id && pending->result.has_value());
        });
        if (pending && pending->id == request_id && pending->result) {
            auto response = std::move(*pending->result);
            pending.reset();
            return response;
        }
        if (closed.load(std::memory_order_acquire)) {
            if (pending && pending->id == request_id) {
                pending.reset();
            }
            return closed_error_locked();
        }
        if (!completed && pending && pending->id == request_id) {
            pending.reset();
        }
        return make_error(ErrorCode::timeout, "attachment command response timed out");
    }

    [[nodiscard]] Result<Event> next_event(Timeout timeout) {
        if (timeout < Timeout::zero()) {
            return make_error(ErrorCode::invalid_argument, "stream timeout cannot be negative");
        }
        const auto deadline = Clock::now() + timeout;
        std::unique_lock state_lock(state_mutex);
        const bool ready = state_changed.wait_until(state_lock, deadline, [&] {
            return !events.empty() || closed.load(std::memory_order_acquire);
        });
        if (!events.empty()) {
            Event event = std::move(events.front());
            events.pop_front();
            const bool terminal = event.name() == "detached";
            state_lock.unlock();
            if (terminal) {
                shutdown();
            }
            return event;
        }
        if (closed.load(std::memory_order_acquire)) {
            return closed_error_locked();
        }
        if (!ready) {
            return make_error(ErrorCode::timeout, "attachment event timed out");
        }
        return make_error(ErrorCode::protocol, "attachment event router lost its state");
    }

    void shutdown() noexcept {
        const bool was_closed = closed.exchange(true, std::memory_order_acq_rel);
        if (!was_closed && transport) {
            transport->close();
        }
        state_changed.notify_all();

        std::lock_guard join_lock(join_mutex);
        if (reader.joinable() && reader.get_id() != std::this_thread::get_id()) {
            reader.join();
        }
    }

    [[nodiscard]] Error closed_error() {
        std::lock_guard state_lock(state_mutex);
        return closed_error_locked();
    }

    [[nodiscard]] Error closed_error_locked() const {
        if (terminal_error) {
            return *terminal_error;
        }
        return make_error(ErrorCode::closed, "attachment is closed");
    }

    void fail(Error error) noexcept {
        {
            std::lock_guard state_lock(state_mutex);
            if (closed.load(std::memory_order_acquire)) {
                return;
            }
            terminal_error = std::move(error);
            closed.store(true, std::memory_order_release);
        }
        transport->close();
        state_changed.notify_all();
    }

    void read_messages() noexcept {
        constexpr Timeout reader_timeout = std::chrono::hours(24);
        while (!closed.load(std::memory_order_acquire)) {
            auto wire = transport->receive(reader_timeout);
            if (!wire) {
                if (wire.error().code == ErrorCode::timeout &&
                    !closed.load(std::memory_order_acquire)) {
                    continue;
                }
                if (!closed.load(std::memory_order_acquire)) {
                    fail(std::move(wire).error());
                }
                return;
            }
            auto message = Json::parse(wire.value(), options.json_limits);
            if (!message) {
                fail(std::move(message).error());
                return;
            }
            if (!message.value().is_object()) {
                fail(make_error(
                    ErrorCode::protocol,
                    "server attachment message must be a JSON object"));
                return;
            }
            if (message.value().find("event")) {
                auto event = decode_value<Event>(message.value());
                if (!event) {
                    fail(std::move(event).error());
                    return;
                }
                {
                    std::lock_guard state_lock(state_mutex);
                    if (closed.load(std::memory_order_acquire)) {
                        return;
                    }
                    if (events.size() >= options.max_buffered_stream_events) {
                        terminal_error = make_error(
                            ErrorCode::protocol, "attachment event buffer limit exceeded");
                        closed.store(true, std::memory_order_release);
                    } else {
                        events.push_back(std::move(event).value());
                    }
                }
                if (closed.load(std::memory_order_acquire)) {
                    transport->close();
                    state_changed.notify_all();
                    return;
                }
                state_changed.notify_all();
                continue;
            }

            std::lock_guard state_lock(state_mutex);
            if (closed.load(std::memory_order_acquire) || !pending) {
                continue;
            }
            if (const Json* id = message.value().find("id");
                id && !same_request_id(*id, pending->id)) {
                continue;
            }
            pending->result = successful_response(message.value());
            state_changed.notify_all();
        }
    }

    std::unique_ptr<Transport> transport;
    ClientOptions options;
    Id surface;
    std::uint64_t client_id;
    std::deque<Event> events;
    std::atomic<std::uint64_t> next_request_id;
    std::atomic<bool> closed{false};
    std::mutex command_mutex;
    std::mutex state_mutex;
    std::condition_variable state_changed;
    std::optional<PendingResponse> pending;
    std::optional<Error> terminal_error;
    std::mutex join_mutex;
    std::thread reader;
};

SurfaceAttachment::SurfaceAttachment(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

SurfaceAttachment::SurfaceAttachment(SurfaceAttachment&& other) noexcept = default;

SurfaceAttachment& SurfaceAttachment::operator=(SurfaceAttachment&& other) noexcept {
    if (this != &other) {
        close();
        impl_ = std::move(other.impl_);
    }
    return *this;
}

SurfaceAttachment::~SurfaceAttachment() { close(); }

Result<SurfaceAttachment> SurfaceAttachment::connect(
    const AttachSurfaceRequest& request,
    ClientOptions options,
    RequestOptions request_options) {
    auto transport = connect_transport(options);
    if (!transport) {
        return std::move(transport).error();
    }
    const Timeout operation_timeout = request_options.timeout.value_or(options.timeout);
    if (operation_timeout <= Timeout::zero()) {
        transport.value()->close();
        return make_error(ErrorCode::invalid_argument, "request timeout must be positive");
    }

    std::deque<Event> buffered_events;
    Bootstrap bootstrap{
        *transport.value(),
        options,
        buffered_events,
    };
    auto clients_response = bootstrap.request("list-clients", {}, operation_timeout);
    if (!clients_response) {
        transport.value()->close();
        return std::move(clients_response).error();
    }
    auto own_client_id = self_client_id(clients_response.value());
    if (!own_client_id) {
        transport.value()->close();
        return std::move(own_client_id).error();
    }

    auto encoded_request = encode_value(request);
    if (!encoded_request) {
        transport.value()->close();
        return std::move(encoded_request).error();
    }
    auto parameters = encoded_request.value().as_object();
    if (!parameters) {
        transport.value()->close();
        return std::move(parameters).error();
    }
    (*parameters.value())["mode"] = Json("render");
    auto attached = bootstrap.request(
        "attach-surface", *parameters.value(), operation_timeout);
    if (!attached) {
        transport.value()->close();
        return std::move(attached).error();
    }

    auto impl = std::make_unique<Impl>(
        std::move(transport).value(),
        std::move(options),
        request.surface,
        own_client_id.value(),
        std::move(buffered_events),
        bootstrap.next_request_id);
    try {
        impl->start_reader();
    } catch (const std::system_error& error) {
        impl->shutdown();
        return make_error(
            ErrorCode::connection,
            std::string("cannot start attachment event router: ") + error.what());
    }
    return SurfaceAttachment(std::move(impl));
}

Id SurfaceAttachment::surface() const noexcept {
    return impl_ ? impl_->surface : Id{};
}

std::uint64_t SurfaceAttachment::client_id() const noexcept {
    return impl_ ? impl_->client_id : 0;
}

Result<Event> SurfaceAttachment::next() {
    if (!impl_) {
        return make_error(ErrorCode::closed, "attachment is not initialized");
    }
    while (true) {
        auto event = impl_->next_event(impl_->options.timeout);
        if (event || event.error().code != ErrorCode::timeout) {
            return event;
        }
    }
}

Result<Event> SurfaceAttachment::next(Timeout timeout) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "attachment is not initialized");
    }
    return impl_->next_event(timeout);
}

Result<ResizeSurfaceResult> SurfaceAttachment::resize(
    std::uint16_t cols,
    std::uint16_t rows,
    RequestOptions options) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "attachment is not initialized");
    }
    auto encoded = encode_value(ResizeSurfaceRequest{
        .cols = cols,
        .rows = rows,
        .surface = impl_->surface,
    });
    if (!encoded) {
        return std::move(encoded).error();
    }
    auto parameters = encoded.value().as_object();
    if (!parameters) {
        return std::move(parameters).error();
    }
    auto response =
        impl_->request("resize-surface", *parameters.value(), options.timeout);
    if (!response) {
        return std::move(response).error();
    }
    return decode_value<ResizeSurfaceResult>(response.value());
}

Result<EmptyResult> SurfaceAttachment::set_sizing(
    bool enabled,
    bool exclusive,
    RequestOptions options) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "attachment is not initialized");
    }
    auto encoded = encode_value(SetClientSizingRequest{
        .client = Field<std::uint64_t>(impl_->client_id),
        .enabled = enabled,
        .exclusive = exclusive,
        .surface = impl_->surface,
    });
    if (!encoded) {
        return std::move(encoded).error();
    }
    auto parameters = encoded.value().as_object();
    if (!parameters) {
        return std::move(parameters).error();
    }
    auto response =
        impl_->request("set-client-sizing", *parameters.value(), options.timeout);
    if (!response) {
        return std::move(response).error();
    }
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> SurfaceAttachment::release_size(RequestOptions options) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "attachment is not initialized");
    }
    auto encoded = encode_value(ReleaseSurfaceSizeRequest{.surface = impl_->surface});
    if (!encoded) {
        return std::move(encoded).error();
    }
    auto parameters = encoded.value().as_object();
    if (!parameters) {
        return std::move(parameters).error();
    }
    auto response =
        impl_->request("release-surface-size", *parameters.value(), options.timeout);
    if (!response) {
        return std::move(response).error();
    }
    return decode_value<EmptyResult>(response.value());
}

void SurfaceAttachment::close() noexcept {
    if (impl_) {
        impl_->shutdown();
    }
}

bool SurfaceAttachment::closed() const noexcept {
    return !impl_ || impl_->closed.load(std::memory_order_acquire);
}

Result<RenderAttachment> open_render_attachment(
    const AttachSurfaceRequest& request,
    ClientOptions options,
    RequestOptions request_options) {
    return RenderAttachment::connect(
        request, std::move(options), std::move(request_options));
}

}  // namespace cmux::raw
