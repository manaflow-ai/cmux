#include "test.hpp"
#include "cmux/resource.hpp"

#include <string>
#include <array>
#include <utility>

TEST("machine catalog preserves remote owners and non-secret metadata") {
    for (const auto& [origin, expected] : std::array{
             std::pair{"local", cmux::MachineOrigin::local},
             std::pair{"cloud", cmux::MachineOrigin::cloud},
             std::pair{"ssh", cmux::MachineOrigin::ssh},
             std::pair{"server", cmux::MachineOrigin::server}}) {
        const std::string text = std::string("{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"server\",\"origin\":\"") + origin +
            "\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false,\"platform\":{\"os\":\"linux\",\"arch\":null},\"capabilities\":[\"terminal\"]}";
        const auto parsed = cmux::Json::parse(text);
        CHECK(parsed);
        const auto decoded = cmux::detail::decode_value<cmux::MachineSnapshot>(parsed.value());
        CHECK(decoded);
        CHECK_EQ(decoded.value().origin, expected);
        CHECK(decoded.value().platform.has_value());
        CHECK_EQ(decoded.value().platform->os.value(), "linux");
        CHECK(!decoded.value().platform->arch.has_value());
        CHECK_EQ(decoded.value().capabilities, std::vector<std::string>{"terminal"});
    }
}

TEST("machine catalog preserves legacy defaults") {
    const auto parsed = cmux::Json::parse("{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"local\",\"origin\":\"local\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false}");
    CHECK(parsed);
    const auto decoded = cmux::detail::decode_value<cmux::MachineSnapshot>(parsed.value());
    CHECK(decoded);
    CHECK(!decoded.value().platform.has_value());
    CHECK(decoded.value().capabilities.empty());
}
