#include "cmux/transport.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>
#include <vector>

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
    auto error = make_error(code, std::string(operation) + ": " + std::string(std::strerror(number)));
    error.system_errno = number;
    return error;
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

[[nodiscard]] bool runtime_socket_path_fits(
    std::string_view base_view,
    std::string_view session) noexcept {
    constexpr std::size_t capacity = sizeof(sockaddr_un{}.sun_path);
    const auto base = base_view.empty() ? std::string_view("/tmp") : base_view;
    std::size_t length = base.size();
    const auto append_length = [&](std::size_t amount) noexcept {
        if (amount > capacity || length > capacity - amount) {
            return false;
        }
        length += amount;
        return true;
    };

    if (!base.empty() && base.back() != '/' && !append_length(1U)) {
        return false;
    }
    if (!append_length(sizeof("cmux-tui-") - 1U)) {
        return false;
    }
    auto uid = static_cast<unsigned long>(::getuid());
    std::size_t uid_length = 1U;
    while (uid >= 10U) {
        uid /= 10U;
        ++uid_length;
    }
    if (!append_length(uid_length) || !append_length(1U) ||
        !append_length(session.size()) ||
        !append_length(sizeof(".sock") - 1U)) {
        return false;
    }
    return length < capacity;
}

[[nodiscard]] std::string runtime_socket_path(
    std::string_view base_view,
    std::string_view session) {
    std::string base(base_view.empty() ? std::string_view("/tmp") : base_view);
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

[[nodiscard]] std::string runtime_path(
    std::string_view base_view,
    std::string_view directory,
    std::string_view leaf) {
    std::string path(base_view.empty() ? std::string_view("/tmp") : base_view);
    if (path.back() != '/') {
        path.push_back('/');
    }
    path.append(directory);
    if (!leaf.empty()) {
        path.push_back('/');
        path.append(leaf);
    }
    return path;
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

[[nodiscard]] constexpr std::uint32_t rotate_right(
    std::uint32_t value,
    unsigned amount) noexcept {
    return (value >> amount) | (value << (32U - amount));
}

[[nodiscard]] std::string sha256_hex(std::string_view value) {
    static constexpr std::array<std::uint32_t, 64> round_constants{
        0x428A2F98U, 0x71374491U, 0xB5C0FBCFU, 0xE9B5DBA5U,
        0x3956C25BU, 0x59F111F1U, 0x923F82A4U, 0xAB1C5ED5U,
        0xD807AA98U, 0x12835B01U, 0x243185BEU, 0x550C7DC3U,
        0x72BE5D74U, 0x80DEB1FEU, 0x9BDC06A7U, 0xC19BF174U,
        0xE49B69C1U, 0xEFBE4786U, 0x0FC19DC6U, 0x240CA1CCU,
        0x2DE92C6FU, 0x4A7484AAU, 0x5CB0A9DCU, 0x76F988DAU,
        0x983E5152U, 0xA831C66DU, 0xB00327C8U, 0xBF597FC7U,
        0xC6E00BF3U, 0xD5A79147U, 0x06CA6351U, 0x14292967U,
        0x27B70A85U, 0x2E1B2138U, 0x4D2C6DFCU, 0x53380D13U,
        0x650A7354U, 0x766A0ABBU, 0x81C2C92EU, 0x92722C85U,
        0xA2BFE8A1U, 0xA81A664BU, 0xC24B8B70U, 0xC76C51A3U,
        0xD192E819U, 0xD6990624U, 0xF40E3585U, 0x106AA070U,
        0x19A4C116U, 0x1E376C08U, 0x2748774CU, 0x34B0BCB5U,
        0x391C0CB3U, 0x4ED8AA4AU, 0x5B9CCA4FU, 0x682E6FF3U,
        0x748F82EEU, 0x78A5636FU, 0x84C87814U, 0x8CC70208U,
        0x90BEFFFAU, 0xA4506CEBU, 0xBEF9A3F7U, 0xC67178F2U,
    };
    std::array<std::uint32_t, 8> state{
        0x6A09E667U,
        0xBB67AE85U,
        0x3C6EF372U,
        0xA54FF53AU,
        0x510E527FU,
        0x9B05688CU,
        0x1F83D9ABU,
        0x5BE0CD19U,
    };

    std::vector<std::uint8_t> message;
    message.reserve(value.size() + 72U);
    for (const auto byte : value) {
        message.push_back(static_cast<std::uint8_t>(static_cast<unsigned char>(byte)));
    }
    const auto bit_length = static_cast<std::uint64_t>(message.size()) * 8U;
    message.push_back(0x80U);
    while ((message.size() % 64U) != 56U) {
        message.push_back(0U);
    }
    for (const auto shift : {56U, 48U, 40U, 32U, 24U, 16U, 8U, 0U}) {
        message.push_back(static_cast<std::uint8_t>((bit_length >> shift) & 0xFFU));
    }

    for (std::size_t chunk = 0; chunk < message.size(); chunk += 64U) {
        std::array<std::uint32_t, 64> words{};
        for (std::size_t index = 0; index < 16U; ++index) {
            const auto offset = chunk + (index * 4U);
            words[index] =
                (static_cast<std::uint32_t>(message[offset]) << 24U) |
                (static_cast<std::uint32_t>(message[offset + 1U]) << 16U) |
                (static_cast<std::uint32_t>(message[offset + 2U]) << 8U) |
                static_cast<std::uint32_t>(message[offset + 3U]);
        }
        for (std::size_t index = 16U; index < words.size(); ++index) {
            const auto first =
                rotate_right(words[index - 15U], 7U) ^
                rotate_right(words[index - 15U], 18U) ^
                (words[index - 15U] >> 3U);
            const auto second =
                rotate_right(words[index - 2U], 17U) ^
                rotate_right(words[index - 2U], 19U) ^
                (words[index - 2U] >> 10U);
            words[index] = words[index - 16U] + first + words[index - 7U] + second;
        }

        auto a = state[0];
        auto b = state[1];
        auto c = state[2];
        auto d = state[3];
        auto e = state[4];
        auto f = state[5];
        auto g = state[6];
        auto h = state[7];
        for (std::size_t index = 0; index < words.size(); ++index) {
            const auto upper =
                rotate_right(e, 6U) ^ rotate_right(e, 11U) ^ rotate_right(e, 25U);
            const auto choose = (e & f) ^ ((~e) & g);
            const auto first = h + upper + choose + round_constants[index] + words[index];
            const auto lower =
                rotate_right(a, 2U) ^ rotate_right(a, 13U) ^ rotate_right(a, 22U);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto second = lower + majority;
            h = g;
            g = f;
            f = e;
            e = d + first;
            d = c;
            c = b;
            b = a;
            a = first + second;
        }
        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
        state[5] += f;
        state[6] += g;
        state[7] += h;
    }

    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(64U);
    for (const auto word : state) {
        for (const auto shift : {28U, 24U, 20U, 16U, 12U, 8U, 4U, 0U}) {
            result.push_back(digits[(word >> shift) & 0x0FU]);
        }
    }
    return result;
}

[[nodiscard]] std::string hashed_session_socket_path(
    std::string_view base,
    std::string_view session) {
    const auto directory = std::string("cmux-tui-hashed-") +
        std::to_string(static_cast<unsigned long>(::getuid()));
    const auto leaf = sha256_hex(session) + ".sock";
    return runtime_path(base, directory, leaf);
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
    const auto leaf = sha256_hex(session) + ".sock";
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
UnixTransport& UnixTransport::operator=(UnixTransport&& other) noexcept {
    if (this == &other) {
        return *this;
    }
    // The defaulted assignment destroys the old Impl through unique_ptr. Impl
    // does not own the descriptor, so that would leak an open socket whenever
    // an already-connected transport is overwritten.
    if (impl_) {
        close();
        if (impl_->fd >= 0) {
            ::close(impl_->fd);
            impl_->fd = -1;
        }
    }
    impl_ = std::move(other.impl_);
    return *this;
}

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
        // Nonblocking connect may report any of these values while the
        // connection is still in progress. Linux documents EAGAIN for
        // resource exhaustion and EWOULDBLOCK where it differs from
        // EAGAIN, while POSIX specifies EINPROGRESS for this case.
        if (errno != EINPROGRESS && errno != EAGAIN && errno != EWOULDBLOCK) {
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
    const auto preferred_base = runtime_base();
    if (runtime_socket_path_fits(preferred_base, session)) {
        return runtime_socket_path(preferred_base, session);
    }
    constexpr std::string_view fallback_base = "/tmp";
    if (runtime_socket_path_fits(fallback_base, session)) {
        return runtime_socket_path(fallback_base, session);
    }
    auto hashed = hashed_session_socket_path(preferred_base, session);
    if (unix_socket_path_fits(hashed)) {
        return hashed;
    }
    hashed = hashed_session_socket_path(fallback_base, session);
    if (!unix_socket_path_fits(hashed)) {
        return make_error(ErrorCode::invalid_argument, "derived Unix socket path is too long");
    }
    return hashed;
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
