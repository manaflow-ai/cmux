#include "test.hpp"

#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <future>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "cmux/transport.hpp"

namespace {

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
    std::promise<void> reader_started;
    auto reader_ready = reader_started.get_future();
    std::thread reader([&] {
        reader_started.set_value();
        read = transport->receive(std::chrono::seconds(30));
    });
    CHECK(reader_ready.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
    transport->close();
    reader.join();
    peer.join();
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
