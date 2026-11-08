#ifndef unix
#define unix 0x434d5558
#endif

constexpr auto kUnixMacroBeforeCmuxInclude = unix;

#include "cmux/client.hpp"
#include "cmux/raw/client.hpp"
#include "test.hpp"

#ifndef unix
#error "cmux headers must preserve the caller's unix macro"
#endif

static_assert(unix == kUnixMacroBeforeCmuxInclude);

TEST("public and generated enums survive caller macros and preserve wire values") {
    cmux::ClientSnapshot snapshot;
    CHECK_EQ(snapshot.transport, cmux::ClientTransport::unix_socket);

    auto wire = cmux::raw::Json::parse(R"("unix")");
    CHECK(wire);

    auto decoded = cmux::raw::decode_value<cmux::raw::ClientTransport>(wire.value());
    CHECK(decoded);
    CHECK_EQ(decoded.value(), cmux::raw::ClientTransport::unix_);

    auto encoded = cmux::raw::encode_value(decoded.value());
    CHECK(encoded);
    CHECK_EQ(encoded.value().as_string().value(), std::string_view("unix"));
    CHECK_EQ(unix, kUnixMacroBeforeCmuxInclude);
}
