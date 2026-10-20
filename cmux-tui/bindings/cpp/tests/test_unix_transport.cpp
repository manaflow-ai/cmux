#include "test.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <future>
#include <initializer_list>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "cmux/resource.hpp"
#include "cmux/raw/client_core.hpp"
#include "cmux/transport.hpp"
#include "socket_path_internal.hpp"

namespace {

std::mutex environment_mutex;

TEST("hashed socket detection requires the exact parent component and uid") {
    constexpr unsigned long uid = 501;

    CHECK(cmux::detail::is_hashed_socket_path_for_uid(
        "/tmp/cmux-tui-hashed-501/session.sock", uid));
    CHECK(!cmux::detail::is_hashed_socket_path_for_uid(
        "/tmp/cmux-tui-hashed-marker/cmux-tui-hashed-501.sock", uid));
    CHECK(!cmux::detail::is_hashed_socket_path_for_uid(
        "/tmp/cmux-tui-hashed-501-marker/session.sock", uid));
    CHECK(!cmux::detail::is_hashed_socket_path_for_uid(
        "/tmp/cmux-tui-hashed-502/session.sock", uid));
    CHECK(!cmux::detail::is_hashed_socket_path_for_uid(
        "/tmp/cmux-tui-hashed-501/", uid));
}

struct ScopedEnvironment {
    struct Saved {
        std::string name;
        std::optional<std::string> value;
    };

    explicit ScopedEnvironment(
        std::initializer_list<std::string_view> names) {
        saved.reserve(names.size());
        for (const auto name : names) {
            const auto owned = std::string(name);
            const char* value = std::getenv(owned.c_str());
            saved.push_back({
                owned,
                value ? std::optional<std::string>(value) : std::nullopt,
            });
        }
    }

    ScopedEnvironment(const ScopedEnvironment&) = delete;
    ScopedEnvironment& operator=(const ScopedEnvironment&) = delete;

    ~ScopedEnvironment() {
        for (auto item = saved.rbegin(); item != saved.rend(); ++item) {
            if (item->value) {
                (void)::setenv(
                    item->name.c_str(), item->value->c_str(), 1);
            } else {
                (void)::unsetenv(item->name.c_str());
            }
        }
    }

    void set(std::string_view name, std::string_view value) {
        const auto owned_name = std::string(name);
        const auto owned_value = std::string(value);
        CHECK(
            ::setenv(
                owned_name.c_str(), owned_value.c_str(), 1) == 0);
    }

    void unset(std::string_view name) {
        const auto owned = std::string(name);
        CHECK(::unsetenv(owned.c_str()) == 0);
    }

    std::vector<Saved> saved;
};

std::string expected_socket(
    std::string base,
    std::string_view session = "main") {
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

struct UnixServer {
    std::filesystem::path directory;
    std::string path;
    int listener = -1;

    UnixServer() {
        std::array<char, 64> pattern{};
        std::snprintf(
            pattern.data(), pattern.size(), "/tmp/cmux-cpp-test-%lu-XXXXXX",
            static_cast<unsigned long>(::getpid()));
        char* created = ::mkdtemp(pattern.data());
        CHECK(created != nullptr);
        directory = created;
        path = (directory / "socket").string();
        listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
        CHECK(listener >= 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        CHECK(
            ::bind(
                listener, reinterpret_cast<const sockaddr*>(&address),
                static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.size() + 1)) == 0);
        CHECK(::listen(listener, 1) == 0);
    }

    ~UnixServer() {
        if (listener >= 0) {
            ::close(listener);
        }
        std::error_code ignored;
        std::filesystem::remove_all(directory, ignored);
    }
};

}  // namespace

TEST("default socket discovery prefers XDG_RUNTIME_DIR") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-xdg");
    environment.unset("TMPDIR");

    CHECK_EQ(
        cmux::default_socket_path(),
        expected_socket("/tmp/cmux-cpp-xdg"));
    CHECK_EQ(
        cmux::default_socket_path("named"),
        expected_socket("/tmp/cmux-cpp-xdg", "named"));
}

TEST("default socket discovery gives XDG_RUNTIME_DIR priority") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-xdg");
    environment.set("TMPDIR", "/tmp/cmux-cpp-tmp");

    CHECK_EQ(
        cmux::default_socket_path(),
        expected_socket("/tmp/cmux-cpp-xdg"));
}

TEST("default socket discovery falls back to TMPDIR") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.unset("XDG_RUNTIME_DIR");
    environment.set("TMPDIR", "/tmp/cmux-cpp-tmp///");

    CHECK_EQ(
        cmux::default_socket_path(),
        expected_socket("/tmp/cmux-cpp-tmp///"));
}

TEST("default socket discovery falls back to slash tmp") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.unset("XDG_RUNTIME_DIR");
    environment.unset("TMPDIR");

    CHECK_EQ(
        cmux::default_socket_path(),
        expected_socket("/tmp"));
}

TEST("default socket wrapper isolates empty session") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-xdg");
    environment.unset("TMPDIR");

    const auto empty = cmux::default_socket_path("");
    CHECK(empty != expected_socket("/tmp/cmux-cpp-xdg", "main"));
    CHECK(empty.find("cmux-tui-invalid-") != std::string::npos);
    CHECK(empty.ends_with(".sock"));

    auto fallible = cmux::try_default_socket_path("");
    CHECK(!fallible);
    if (!fallible) {
        CHECK_EQ(fallible.error().code, cmux::ErrorCode::invalid_argument);
    }
}

TEST("default socket discovery shortens paths that exceed sockaddr_un") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set(
        "XDG_RUNTIME_DIR",
        "/tmp/" + std::string(sizeof(sockaddr_un{}.sun_path), 'x'));
    environment.set("TMPDIR", "/tmp/cmux-cpp-ignored");

    const auto path = cmux::default_socket_path("long-runtime");
    CHECK_EQ(path, expected_socket("/tmp", "long-runtime"));
    CHECK(path.size() < sizeof(sockaddr_un{}.sun_path));
}

TEST("long session socket path uses a bindable digest fallback") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/run/user/501");
    environment.unset("TMPDIR");

    const auto session = std::string("legacy-") + std::string(200, 'x');
    auto result = cmux::try_default_socket_path(session);
    CHECK(result);
    if (!result) {
        return;
    }
    const auto& path = result.value();
    const auto expected =
        std::string("/run/user/501/cmux-tui-hashed-") +
        std::to_string(static_cast<unsigned long>(::getuid())) +
        "/e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock";
    CHECK_EQ(path, expected);
    CHECK(path.size() < sizeof(sockaddr_un{}.sun_path));
    if (path.size() >= sizeof(sockaddr_un{}.sun_path)) {
        return;
    }

    UnixServer server;
    const auto directory = server.directory.string();
    CHECK(path.size() > directory.size() + 1U);
    if (path.size() <= directory.size() + 1U) {
        return;
    }
    const auto leaf_length = path.size() - directory.size() - 1U;
    CHECK(leaf_length > std::string_view(".sock").size());
    if (leaf_length <= std::string_view(".sock").size()) {
        return;
    }
    const auto bind_path = (server.directory /
        (std::string(leaf_length - std::string_view(".sock").size(), 'x') + ".sock"))
        .string();
    CHECK_EQ(bind_path.size(), path.size());
    const int listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(listener >= 0);
    if (listener < 0) {
        return;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, bind_path.c_str(), bind_path.size() + 1);
    CHECK(
        ::bind(
            listener,
            reinterpret_cast<const sockaddr*>(&address),
            static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + bind_path.size() + 1)) == 0
    );
    ::close(listener);
    std::error_code ignored;
    std::filesystem::remove(bind_path, ignored);
}

TEST("hashed session socket path falls back to slash tmp when runtime base is too long") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set(
        "XDG_RUNTIME_DIR",
        "/tmp/" + std::string(sizeof(sockaddr_un{}.sun_path), 'x'));
    environment.unset("TMPDIR");

    const auto session = std::string("legacy-") + std::string(200, 'x');
    auto result = cmux::try_default_socket_path(session);
    CHECK(result);
    if (!result) {
        return;
    }
    CHECK(result.value().starts_with(
        "/tmp/cmux-tui-hashed-" +
        std::to_string(static_cast<unsigned long>(::getuid())) + "/"));
    CHECK(result.value().ends_with(".sock"));
    CHECK(result.value().size() < sizeof(sockaddr_un{}.sun_path));
}

TEST("very long session length uses a bounded digest fallback") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/run/user/501");
    environment.unset("TMPDIR");

    const auto session = std::string(64U * 1024U, 'x');
    auto result = cmux::try_default_socket_path(session);
    CHECK(result);
    if (!result) {
        return;
    }
    CHECK(result.value().starts_with(
        "/run/user/501/cmux-tui-hashed-" +
        std::to_string(static_cast<unsigned long>(::getuid())) + "/"));
    CHECK(result.value().ends_with(".sock"));
    CHECK(result.value().size() < sizeof(sockaddr_un{}.sun_path));
}

TEST("non-ASCII long session uses shared UTF-8 SHA-256 digest") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({
        "CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "XDG_RUNTIME_DIR", "TMPDIR"
    });
    environment.unset("CMUX_TUI_SOCKET");
    environment.unset("CMUX_MUX_SOCKET");
    environment.set("XDG_RUNTIME_DIR", "/run/user/501");
    environment.unset("TMPDIR");

    // Build the repeated UTF-8 vector without depending on source-file encoding.
    const std::string pair = "\xE5\x90\x8D\xE5\x89\x8D";
    const auto repeated = [&] {
        std::string value;
        value.reserve(pair.size() * 100U);
        for (int index = 0; index < 100; ++index) {
            value += pair;
        }
        return value;
    }();
    auto result = cmux::try_default_socket_path(repeated);
    CHECK(result);
    if (!result) {
        return;
    }
    const auto expected =
        std::string("/run/user/501/cmux-tui-hashed-") +
        std::to_string(static_cast<unsigned long>(::getuid())) +
        "/0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3.sock";
    CHECK_EQ(result.value(), expected);
}

TEST("default socket discovery uses strict sockaddr_un capacity") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.unset("TMPDIR");

    const std::size_t capacity = sizeof(sockaddr_un{}.sun_path);
    const auto suffix =
        std::string("/cmux-tui-") +
        std::to_string(static_cast<unsigned long>(::getuid())) +
        "/main.sock";
    CHECK(capacity > suffix.size() + 1U);

    std::string capacity_minus_one(
        capacity - 1U - suffix.size(), 'x');
    capacity_minus_one.front() = '/';
    environment.set("XDG_RUNTIME_DIR", capacity_minus_one);
    const auto preferred = cmux::default_socket_path();
    CHECK_EQ(preferred, capacity_minus_one + suffix);
    CHECK_EQ(preferred.size(), capacity - 1U);

    std::string capacity_exact(
        capacity - suffix.size(), 'y');
    capacity_exact.front() = '/';
    environment.set("XDG_RUNTIME_DIR", capacity_exact);
    CHECK_EQ(cmux::default_socket_path(), expected_socket("/tmp"));
}

TEST("default socket discovery counts trailing slashes without normalizing") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.unset("TMPDIR");

    const std::size_t capacity = sizeof(sockaddr_un{}.sun_path);
    const auto suffix =
        std::string("/cmux-tui-") +
        std::to_string(static_cast<unsigned long>(::getuid())) +
        "/main.sock";
    CHECK(capacity > suffix.size() + 1U);

    std::string base(capacity - 1U - suffix.size(), 'z');
    base.front() = '/';
    environment.set("XDG_RUNTIME_DIR", base + "////");
    CHECK_EQ(cmux::default_socket_path(), expected_socket("/tmp"));
}

TEST("derived socket paths reject invalid session names") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({
        "CMUX_TUI_SOCKET",
        "CMUX_MUX_SOCKET",
        "XDG_RUNTIME_DIR",
        "TMPDIR",
    });
    environment.unset("CMUX_TUI_SOCKET");
    environment.unset("CMUX_MUX_SOCKET");
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-session");
    environment.unset("TMPDIR");

    const std::vector<std::string> invalid_sessions{
        "",
        ".",
        "..",
        "../other",
        "a/b",
        "a\\b",
        "line\nbreak",
        std::string("bad\0name", 8),
        "line\xED\xA0\x80" "break",
        "line\xC2\x85" "break",
        "line\xE2\x80\xA8" "break",
        "line\xE2\x80\xA9" "break",
    };
    for (const auto& session : invalid_sessions) {
        auto path = cmux::resolve_socket_path("", session);
        CHECK(!path);
        CHECK_EQ(path.error().code, cmux::ErrorCode::invalid_argument);
    }

    const std::vector<std::string> valid_sessions{
        "A",
        "a.b_C-9",
        ".hidden",
        "_leading",
        "-leading",
        "contains space",
        "名前",
        std::string(200, 'a'),
    };
    for (const auto& session : valid_sessions) {
        auto path = cmux::resolve_socket_path("", session);
        CHECK(path);
        const auto preferred =
            expected_socket("/tmp/cmux-cpp-session", session);
        auto expected = preferred;
        if (expected.size() >= sizeof(sockaddr_un{}.sun_path)) {
            expected = expected_socket("/tmp", session);
            if (expected.size() >= sizeof(sockaddr_un{}.sun_path)) {
                expected =
                    std::string("/tmp/cmux-tui-hashed-") +
                    std::to_string(static_cast<unsigned long>(::getuid())) +
                    "/c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5.sock";
            }
        }
        CHECK_EQ(path.value(), expected);
    }
}

TEST("legacy default socket wrapper isolates invalid names") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-session");
    environment.unset("TMPDIR");

    const auto escaped = cmux::default_socket_path("../escape");
    const auto escaped_again = cmux::default_socket_path("../escape");
    const auto nested = cmux::default_socket_path("nested/escape");
    CHECK_EQ(escaped, escaped_again);
    CHECK(escaped != nested);
    CHECK(escaped.find("../") == std::string::npos);
    CHECK(escaped.find("../escape.sock") == std::string::npos);
    CHECK(escaped.find("/cmux-tui-invalid-") != std::string::npos);
    const auto leaf = std::filesystem::path(escaped).filename().string();
    CHECK_EQ(
        leaf,
        "1ba7343c47dc442de7dec43a995deb9a7b62234ecca16d7c6f597b5155bd85b1.sock");
    const auto normalized = std::filesystem::path(escaped).lexically_normal();
    const auto preferred = std::string("/tmp/cmux-cpp-session/cmux-tui-invalid-") +
        std::to_string(static_cast<unsigned long>(::getuid())) + "/" + leaf;
    const auto expected_prefix = preferred.size() < sizeof(sockaddr_un{}.sun_path)
        ? "/tmp/cmux-cpp-session/"
        : "/tmp/";
    CHECK(normalized.string().starts_with(expected_prefix));
}

TEST("fallible default socket paths reject unsafe names before joining") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"XDG_RUNTIME_DIR", "TMPDIR"});
    environment.set("XDG_RUNTIME_DIR", "/tmp/cmux-cpp-session");
    environment.unset("TMPDIR");

    const std::vector<std::string> invalid_sessions{
        "",
        ".",
        "..",
        "../escape",
        "nested/session",
        "nested\\session",
        std::string("bad\0name", 8),
        "bad\nname",
        "bad\xC2\x85" "name",
        "bad\xE2\x80\xA8" "name",
        "bad\xE2\x80\xA9" "name",
    };
    for (const auto& session : invalid_sessions) {
        auto path = cmux::try_default_socket_path(session);
        CHECK(!path);
        CHECK_EQ(path.error().code, cmux::ErrorCode::invalid_argument);
    }

    for (const auto& session : {
             std::string("legacy name"),
             std::string("名前"),
             std::string("_legacy"),
             std::string("-legacy"),
             std::string("legacy:colon"),
         }) {
        auto path = cmux::try_default_socket_path(session);
        CHECK(path);
        CHECK(path.value().ends_with("/" + session + ".sock"));
    }
    auto long_name = std::string("legacy-") + std::string(200, 'x');
    CHECK(cmux::try_default_socket_path(long_name));
}

TEST("explicit socket paths bypass derived session validation") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment(
        {"CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"});
    environment.unset("CMUX_TUI_SOCKET");
    environment.unset("CMUX_MUX_SOCKET");

    auto explicit_path =
        cmux::resolve_socket_path("/tmp/../literal.sock", "../invalid");
    CHECK(explicit_path);
    CHECK_EQ(explicit_path.value(), std::string("/tmp/../literal.sock"));

    environment.set("CMUX_TUI_SOCKET", "/tmp/explicit-primary.sock");
    environment.set("CMUX_MUX_SOCKET", "/tmp/explicit-fallback.sock");
    auto primary = cmux::resolve_socket_path("", "../invalid");
    CHECK(primary);
    CHECK_EQ(primary.value(), std::string("/tmp/explicit-primary.sock"));

    environment.unset("CMUX_TUI_SOCKET");
    auto fallback = cmux::resolve_socket_path("", "../invalid");
    CHECK(fallback);
    CHECK_EQ(fallback.value(), std::string("/tmp/explicit-fallback.sock"));
}

TEST("custom transports bypass derived session validation") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment(
        {"CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"});
    environment.unset("CMUX_TUI_SOCKET");
    environment.unset("CMUX_MUX_SOCKET");

    cmux::ClientOptions options;
    options.session = "../invalid";
    options.transport_factory =
        []() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        return cmux::make_error(
            cmux::ErrorCode::connection,
            "custom transport reached");
    };
    auto client = cmux::Client::connect(std::move(options));
    CHECK(!client);
    CHECK_EQ(client.error().code, cmux::ErrorCode::connection);
    CHECK_EQ(client.error().message, std::string("custom transport reached"));
}

TEST("legacy socket fallback preserves a custom stream transport factory") {
    std::lock_guard lock(environment_mutex);
    ScopedEnvironment environment({"CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "XDG_RUNTIME_DIR", "TMPDIR"});
    environment.unset("CMUX_TUI_SOCKET");
    environment.unset("CMUX_MUX_SOCKET");
    environment.unset("XDG_RUNTIME_DIR");
    environment.unset("TMPDIR");
    const auto session =
        std::string("cpp-stream-factory-") + std::to_string(static_cast<unsigned long>(::getpid()));
    const auto directory = std::filesystem::path(
        "/tmp/cmux-tui-" + std::to_string(static_cast<unsigned long>(::getuid())));
    const auto path = directory / (session + ".sock");
    std::error_code ignored;
    std::filesystem::create_directories(directory, ignored);
    std::filesystem::remove(path, ignored);
    const int listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(listener >= 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.string().size() + 1);
    CHECK(::bind(
        listener, reinterpret_cast<const sockaddr*>(&address),
        static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + path.string().size() + 1)) == 0);
    CHECK(::listen(listener, 1) == 0);

    cmux::raw::ClientOptions options;
    options.session = session;
    options.timeout = std::chrono::seconds(1);
    options.stream_transport_factory = []() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
        return cmux::make_error(cmux::ErrorCode::connection, "custom stream factory reached");
    };
    auto client = cmux::raw::detail::ClientCore::connect(std::move(options));
    CHECK(client);
    auto stream = client.value().open_stream("stream", {}, {}, std::chrono::milliseconds(100));
    CHECK(!stream);
    CHECK_EQ(stream.error().code, cmux::ErrorCode::connection);
    CHECK_EQ(stream.error().message, std::string("custom stream factory reached"));

    ::close(listener);
    std::filesystem::remove(path, ignored);
    std::filesystem::remove(directory, ignored);
}

TEST("Unix transport assembles partial JSON-lines frames") {
    UnixServer server;
    std::promise<void> first_part_written;
    std::promise<void> write_second_part;
    auto first_part_ready = first_part_written.get_future();
    auto second_part_ready = write_second_part.get_future();
    std::thread peer([&] {
        const int fd = ::accept(server.listener, nullptr, nullptr);
        CHECK(fd >= 0);
        const std::string first = "{\"ok\":";
        const std::string second = "true}\n{\"next\":1}\n";
        CHECK(::write(fd, first.data(), first.size()) == static_cast<ssize_t>(first.size()));
        first_part_written.set_value();
        second_part_ready.wait();
        CHECK(::write(fd, second.data(), second.size()) == static_cast<ssize_t>(second.size()));
        ::close(fd);
    });
    auto transport = cmux::UnixTransport::connect(server.path, std::chrono::seconds(1));
    CHECK(transport);
    const auto first_part_status = first_part_ready.wait_for(std::chrono::seconds(2));
    auto partial = transport.value()->receive(std::chrono::milliseconds(20));
    write_second_part.set_value();
    CHECK(first_part_status == std::future_status::ready);
    CHECK(!partial);
    CHECK_EQ(partial.error().code, cmux::ErrorCode::timeout);
    auto first = transport.value()->receive(std::chrono::seconds(1));
    auto second = transport.value()->receive(std::chrono::seconds(1));
    CHECK(first);
    CHECK(second);
    CHECK_EQ(first.value(), std::string(R"({"ok":true})"));
    CHECK_EQ(second.value(), std::string(R"({"next":1})"));
    peer.join();
}

TEST("Unix transport times out and close unblocks receive") {
    UnixServer server;
    std::thread peer([&] {
        const int fd = ::accept(server.listener, nullptr, nullptr);
        CHECK(fd >= 0);
        std::array<char, 1> byte{};
        (void)::read(fd, byte.data(), byte.size());
        ::close(fd);
    });
    auto transport_result =
        cmux::UnixTransport::connect(server.path, std::chrono::seconds(1));
    CHECK(transport_result);
    auto transport = std::move(transport_result).value();
    auto timed_out = transport->receive(std::chrono::milliseconds(5));

    cmux::Result<std::string> read =
        cmux::make_error(cmux::ErrorCode::protocol, "not started");
    auto* unix_transport = dynamic_cast<cmux::UnixTransport*>(transport.get());
    CHECK(unix_transport != nullptr);
    std::promise<void> receive_waiting;
    std::once_flag receive_waiting_once;
    auto receive_ready = receive_waiting.get_future();
    unix_transport->set_before_receive_wait_for_testing([&] {
        std::call_once(receive_waiting_once, [&] { receive_waiting.set_value(); });
    });
    std::thread reader([&] { read = transport->receive(std::chrono::seconds(30)); });
    const auto receive_status = receive_ready.wait_for(std::chrono::seconds(2));
    transport->close();
    reader.join();
    peer.join();
    CHECK(receive_status == std::future_status::ready);
    CHECK(!timed_out);
    CHECK_EQ(timed_out.error().code, cmux::ErrorCode::timeout);
    CHECK(!read);
    CHECK_EQ(read.error().code, cmux::ErrorCode::closed);
}

TEST("Unix transport rejects oversized frames") {
    UnixServer server;
    std::thread peer([&] {
        const int fd = ::accept(server.listener, nullptr, nullptr);
        CHECK(fd >= 0);
        const std::string oversized = std::string(64, 'x') + "\n";
        (void)::write(fd, oversized.data(), oversized.size());
        ::close(fd);
    });
    cmux::TransportLimits limits;
    limits.max_message_bytes = 16;
    auto transport =
        cmux::UnixTransport::connect(server.path, std::chrono::seconds(1), limits);
    CHECK(transport);
    auto result = transport.value()->receive(std::chrono::seconds(1));
    peer.join();
    CHECK(!result);
    CHECK_EQ(result.error().code, cmux::ErrorCode::protocol);
}

TEST("Unix transport preserves missing socket errno for fallback classification") {
    const auto path = std::string("/tmp/cmux-cpp-missing-") +
        std::to_string(static_cast<unsigned long>(::getpid())) + ".sock";
    std::error_code ignored;
    std::filesystem::remove(path, ignored);

    auto result = cmux::UnixTransport::connect(path, std::chrono::milliseconds(100));
    CHECK(!result);
    if (!result) {
        CHECK_EQ(result.error().code, cmux::ErrorCode::connection);
        CHECK_EQ(result.error().system_errno, ENOENT);
    }
}

TEST("Unix transport preserves refused socket errno without treating it as missing") {
    UnixServer server;
    ::close(server.listener);
    server.listener = -1;

    auto result = cmux::UnixTransport::connect(server.path, std::chrono::milliseconds(100));
    CHECK(!result);
    if (!result) {
        CHECK_EQ(result.error().code, cmux::ErrorCode::connection);
        CHECK_EQ(result.error().system_errno, ECONNREFUSED);
    }
}
