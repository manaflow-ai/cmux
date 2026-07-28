#ifndef unix
#define unix 0x434d5558
#endif

constexpr auto kUnixMacroBeforeCmuxInclude = unix;

#include "cmux/client.hpp"
#include "test.hpp"

#ifndef unix
#error "cmux headers must preserve the caller's unix macro"
#endif

static_assert(unix == kUnixMacroBeforeCmuxInclude);

TEST("generated enum values survive caller macros and preserve wire values") {
    auto wire = cmux::Json::parse(R"("unix")");
    CHECK(wire);

    auto decoded = cmux::decode_value<cmux::ClientTransport>(wire.value());
    CHECK(decoded);
    CHECK_EQ(decoded.value(), cmux::ClientTransport::unix_);

    auto encoded = cmux::encode_value(decoded.value());
    CHECK(encoded);
    CHECK_EQ(encoded.value().as_string().value(), std::string_view("unix"));
    CHECK_EQ(unix, kUnixMacroBeforeCmuxInclude);
}
