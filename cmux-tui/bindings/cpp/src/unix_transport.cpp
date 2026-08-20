#include "cmux/transport.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace cmux {
namespace {

using Clock = std::chrono::steady_clock;

[[nodiscard]] Error system_error(ErrorCode code, std::string_view operation, int number = errno) {
    return make_error(
        code, std::string(operation) + ": " + std::string(std::strerror(number)));
}

[[nodiscard]] Result<void> wait_for_fd(int fd, short events, Clock::time_point deadline) {
    while (true) {
        const auto now = Clock::now();
        if (now >= deadline) {
            return make_error(ErrorCode::timeout, "transport operation timed out");
        }
        const auto remaining =
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
        const int timeout = static_cast<int>(
            std::min<std::int64_t>(remaining.count() + 1, std::numeric_limits<int>::max()));
        pollfd descriptor{fd, events, 0};
        const int result = ::poll(&descriptor, 1, timeout);
        if (result > 0) {
            if ((descriptor.revents & POLLNVAL) != 0) {
                return make_error(ErrorCode::closed, "transport file descriptor is closed");
            }
            if ((descriptor.revents & (events | POLLERR | POLLHUP)) != 0) {
                return {};
            }
            continue;
        }
        if (result == 0) {
            return make_error(ErrorCode::timeout, "transport operation timed out");
        }
        if (errno != EINTR) {
            return system_error(ErrorCode::connection, "poll failed");
        }
    }
}

[[nodiscard]] bool unix_socket_path_fits(std::string_view path) noexcept {
    sockaddr_un address{};
    return path.size() < sizeof(address.sun_path);
}

[[nodiscard]] std::string runtime_socket_path(
    std::string base,
    std::string_view session) {
    if (base.empty()) {
        base = "/tmp";
    }
    if (base.back() != '/') {
        base.push_back('/');
    }
    base += "cmux-tui-";
    base += std::to_string(static_cast<unsigned long>(::getuid()));
    base.push_back('/');
    base.append(session);
    base += ".sock";
    return base;
}

[[nodiscard]] bool decode_utf8(
    std::string_view text,
    std::size_t& offset,
    std::uint32_t& codepoint) noexcept {
    const auto byte_at = [&](std::size_t index) {
        return static_cast<unsigned char>(text[index]);
    };
    const auto continuation = [&](std::size_t index) {
        return index < text.size() && (byte_at(index) & 0xC0U) == 0x80U;
    };

    const auto first = byte_at(offset++);
    if (first <= 0x7FU) {
        codepoint = first;
        return true;
    }
    if (first >= 0xC2U && first <= 0xDFU) {
        if (!continuation(offset)) {
            return false;
        }
        codepoint = (static_cast<std::uint32_t>(first & 0x1FU) << 6U) |
            (byte_at(offset) & 0x3FU);
        ++offset;
        return true;
    }
    if (first >= 0xE0U && first <= 0xEFU) {
        if (!continuation(offset) || !continuation(offset + 1U)) {
            return false;
        }
        const auto second = byte_at(offset);
        if ((first == 0xE0U && second < 0xA0U) ||
            (first == 0xEDU && second > 0x9FU)) {
            return false;
        }
        codepoint = (static_cast<std::uint32_t>(first & 0x0FU) << 12U) |
            (static_cast<std::uint32_t>(second & 0x3FU) << 6U) |
            (byte_at(offset + 1U) & 0x3FU);
        offset += 2U;
        return true;
    }
    if (first >= 0xF0U && first <= 0xF4U) {
        if (!continuation(offset) || !continuation(offset + 1U) ||
            !continuation(offset + 2U)) {
            return false;
        }
        const auto second = byte_at(offset);
        if ((first == 0xF0U && second < 0x90U) ||
            (first == 0xF4U && second > 0x8FU)) {
            return false;
        }
        codepoint = (static_cast<std::uint32_t>(first & 0x07U) << 18U) |
            (static_cast<std::uint32_t>(second & 0x3FU) << 12U) |
            (static_cast<std::uint32_t>(byte_at(offset + 1U) & 0x3FU) << 6U) |
            (byte_at(offset + 2U) & 0x3FU);
        offset += 3U;
        return true;
    }
    return false;
}

[[nodiscard]] Result<void> validate_session_name(std::string_view session) {
    if (session.empty() || session == "." || session == "..") {
        return make_error(
            ErrorCode::invalid_argument,
            "session name must be a non-empty UTF-8 path component without separators or control characters");
    }

    std::size_t offset = 0;
    while (offset < session.size()) {
        std::uint32_t codepoint = 0;
        if (!decode_utf8(session, offset, codepoint) ||
            codepoint == '/' || codepoint == '\\' || codepoint == '\0' ||
            codepoint < 0x20U ||
            (codepoint >= 0x7FU && codepoint <= 0x9FU) ||
            codepoint == 0x2028U || codepoint == 0x2029U) {
            return make_error(
                ErrorCode::invalid_argument,
                "session name must be a non-empty UTF-8 path component without separators or control characters");
        }
    }
    return {};
}

[[nodiscard]] std::string runtime_base() {
    const char* base = std::getenv("XDG_RUNTIME_DIR");
    if (!base || *base == '\0') {
        base = std::getenv("TMPDIR");
    }
    if (!base || *base == '\0') {
        base = "/tmp";
    }
    return base;
}

[[nodiscard]] std::string fnv1a_hex(std::string_view value) {
    std::uint64_t hash = 0xcbf29ce484222325ULL;
    for (const auto byte : value) {
        hash ^= static_cast<unsigned char>(byte);
        hash *= 0x100000001b3ULL;
    }
    constexpr char digits[] = "0123456789abcdef";
    std::string result(16, '0');
    for (std::size_t index = 0; index < result.size(); ++index) {
        const auto shift = static_cast<unsigned>(60U - (index * 4U));
        result[index] = digits[(hash >> shift) & 0x0FU];
    }
    return result;
}

[[nodiscard]] std::string invalid_session_socket_path_in_runtime_dir(
    std::string_view session,
    std::string base);

[[nodiscard]] std::string invalid_session_socket_path(std::string_view session) {
    return invalid_session_socket_path_in_runtime_dir(session, runtime_base());
}

[[nodiscard]] std::string invalid_session_socket_path_in_runtime_dir(
    std::string_view session,
    std::string base) {
    const auto directory = std::string("cmux-tui-invalid-") +
        std::to_string(static_cast<unsigned long>(::getuid()));
    const auto leaf = fnv1a_hex(session) + ".sock";
    if (base.empty()) {
        base = "/tmp";
    }
    if (base.back() != '/') {
        base.push_back('/');
    }
    auto preferred = base + directory + "/" + leaf;
    if (!unix_socket_path_fits(preferred)) {
        preferred = "/tmp/" + directory + "/" + leaf;
    }
    return preferred;
}

}  // namespace

struct UnixTransport::Impl {
    Impl(int descriptor, std::string socket_path, TransportLimits transport_limits)
        : fd(descriptor), path(std::move(socket_path)), limits(transport_limits) {}

    int fd = -1;
    std::string path;
    TransportLimits limits;
    std::atomic<bool> closed{false};
    std::mutex send_mutex;
    std::mutex receive_mutex;
    std::string receive_buffer;
#if defined(CMUX_CPP_TESTING)
    std::function<void()> before_receive_wait;
#endif
};

UnixTransport::UnixTransport(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
UnixTransport::UnixTransport(UnixTransport&&) noexcept = default;
UnixTransport& UnixTransport::operator=(UnixTransport&&) noexcept = default;

UnixTransport::~UnixTransport() {
    if (!impl_) {
        return;
    }
    close();
    if (impl_->fd >= 0) {
        ::close(impl_->fd);
        impl_->fd = -1;
    }
}

Result<std::unique_ptr<Transport>> UnixTransport::connect(
    std::string path,
    Timeout timeout,
    TransportLimits limits) {
    if (path.empty()) {
        return make_error(ErrorCode::invalid_argument, "Unix socket path cannot be empty");
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (!unix_socket_path_fits(path)) {
        return make_error(ErrorCode::invalid_argument, "Unix socket path is too long");
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);

    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return system_error(ErrorCode::connection, "cannot create Unix socket");
    }
    const int current_flags = ::fcntl(fd, F_GETFL, 0);
    if (current_flags < 0 || ::fcntl(fd, F_SETFL, current_flags | O_NONBLOCK) < 0) {
        const auto error = system_error(ErrorCode::connection, "cannot configure Unix socket");
        ::close(fd);
        return error;
    }
#if defined(SO_NOSIGPIPE)
    int one = 1;
    (void)::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif

    const auto address_length =
        static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.size() + 1);
    if (::connect(fd, reinterpret_cast<const sockaddr*>(&address), address_length) < 0) {
        if (errno != EINPROGRESS) {
            const auto error = system_error(
                ErrorCode::connection, "cannot connect to Unix socket '" + path + "'");
            ::close(fd);
            return error;
        }
        auto ready = wait_for_fd(fd, POLLOUT, Clock::now() + timeout);
        if (!ready) {
            ::close(fd);
            return std::move(ready).error();
        }
        int connect_error = 0;
        socklen_t connect_error_size = sizeof(connect_error);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &connect_error, &connect_error_size) < 0 ||
            connect_error != 0) {
            const int number = connect_error == 0 ? errno : connect_error;
            const auto error = system_error(
                ErrorCode::connection, "cannot connect to Unix socket '" + path + "'", number);
            ::close(fd);
            return error;
        }
    }

    return std::unique_ptr<Transport>(
        new UnixTransport(std::make_unique<Impl>(fd, std::move(path), limits)));
}

Result<void> UnixTransport::send(std::string_view message, Timeout timeout) {
    if (!impl_ || impl_->closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "transport is closed");
    }
    if (message.size() > impl_->limits.max_message_bytes) {
        return make_error(ErrorCode::invalid_argument, "outgoing message exceeds configured limit");
    }
    if (message.find('\n') != std::string_view::npos) {
        return make_error(ErrorCode::invalid_argument, "JSON-lines message contains a newline");
    }
    std::lock_guard lock(impl_->send_mutex);
    const auto deadline = Clock::now() + timeout;
    std::size_t offset = 0;
    while (offset <= message.size()) {
        const char newline = '\n';
        const char* data = offset < message.size() ? message.data() + offset : &newline;
        const std::size_t remaining = offset < message.size() ? message.size() - offset : 1;
#if defined(MSG_NOSIGNAL)
        const ssize_t written = ::send(impl_->fd, data, remaining, MSG_NOSIGNAL);
#else
        const ssize_t written = ::send(impl_->fd, data, remaining, 0);
#endif
        if (written > 0) {
            if (offset < message.size()) {
                offset += static_cast<std::size_t>(written);
            } else {
                return {};
            }
            continue;
        }
        if (written == 0) {
            return make_error(ErrorCode::connection, "socket closed while writing");
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            auto ready = wait_for_fd(impl_->fd, POLLOUT, deadline);
            if (!ready) {
                return ready;
            }
            continue;
        }
        if (errno == EINTR) {
            continue;
        }
        if (impl_->closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "transport is closed");
        }
        return system_error(ErrorCode::connection, "socket write failed");
    }
    return {};
}

Result<std::string> UnixTransport::receive(Timeout timeout) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "transport is closed");
    }
    std::lock_guard lock(impl_->receive_mutex);
    const auto deadline = Clock::now() + timeout;
    while (true) {
        if (const auto newline = impl_->receive_buffer.find('\n'); newline != std::string::npos) {
            if (newline > impl_->limits.max_message_bytes) {
                close();
                return make_error(
                    ErrorCode::protocol,
                    "incoming JSON-lines message exceeds configured limit");
            }
            std::string message = impl_->receive_buffer.substr(0, newline);
            impl_->receive_buffer.erase(0, newline + 1);
            if (!message.empty() && message.back() == '\r') {
                message.pop_back();
            }
            return message;
        }
        if (impl_->receive_buffer.size() > impl_->limits.max_message_bytes) {
            close();
            return make_error(ErrorCode::protocol, "incoming JSON-lines message exceeds configured limit");
        }
        if (impl_->closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "transport is closed");
        }
#if defined(CMUX_CPP_TESTING)
        if (impl_->before_receive_wait) {
            impl_->before_receive_wait();
        }
#endif
        auto ready = wait_for_fd(impl_->fd, POLLIN, deadline);
        if (!ready) {
            if (impl_->closed.load(std::memory_order_acquire)) {
                return make_error(ErrorCode::closed, "transport is closed");
            }
            return std::move(ready).error();
        }
        char buffer[8192];
        const ssize_t count = ::recv(impl_->fd, buffer, sizeof(buffer), 0);
        if (count > 0) {
            impl_->receive_buffer.append(buffer, static_cast<std::size_t>(count));
            continue;
        }
        if (count == 0) {
            if (impl_->closed.load(std::memory_order_acquire)) {
                return make_error(ErrorCode::closed, "transport is closed");
            }
            return make_error(ErrorCode::connection, "session socket closed");
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            continue;
        }
        if (impl_->closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "transport is closed");
        }
        return system_error(ErrorCode::connection, "socket read failed");
    }
}

#if defined(CMUX_CPP_TESTING)
void UnixTransport::set_before_receive_wait_for_testing(std::function<void()> hook) {
    impl_->before_receive_wait = std::move(hook);
}
#endif

void UnixTransport::close() noexcept {
    if (!impl_) {
        return;
    }
    bool expected = false;
    if (impl_->closed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        (void)::shutdown(impl_->fd, SHUT_RDWR);
    }
}

Result<std::string> try_default_socket_path(std::string_view session) {
    auto valid = validate_session_name(session);
    if (!valid) {
        return std::move(valid).error();
    }
    auto preferred = runtime_socket_path(runtime_base(), session);
    if (!unix_socket_path_fits(preferred)) {
        return runtime_socket_path("/tmp", session);
    }
    return preferred;
}

std::string default_socket_path(std::string_view session) {
    auto path = try_default_socket_path(session);
    if (path) {
        return std::move(path).value();
    }
    // Preserve the historical non-fallible helper without ever joining the
    // caller's invalid text. New code should use try_default_socket_path.
    return invalid_session_socket_path(session);
}

std::string socket_path_from_environment() {
    if (const char* path = std::getenv("CMUX_TUI_SOCKET"); path && *path != '\0') {
        return path;
    }
    if (const char* path = std::getenv("CMUX_MUX_SOCKET"); path && *path != '\0') {
        return path;
    }
    return {};
}

Result<std::string> resolve_socket_path(
    std::string_view explicit_path,
    std::string_view session) {
    if (!explicit_path.empty()) {
        return std::string(explicit_path);
    }
    auto environment_path = socket_path_from_environment();
    if (!environment_path.empty()) {
        return environment_path;
    }
    return try_default_socket_path(session);
}

TransportFactory unix_transport_factory(
    std::string path,
    Timeout connect_timeout,
    TransportLimits limits) {
    return [path = std::move(path), connect_timeout, limits]() {
        return UnixTransport::connect(path, connect_timeout, limits);
    };
}

}  // namespace cmux
