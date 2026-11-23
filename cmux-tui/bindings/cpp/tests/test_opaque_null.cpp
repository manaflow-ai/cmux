#include "cmux/raw/client.hpp"
#include "test.hpp"

#include <string>

// Opaque JSON admits null, so a field that is not nullable must reject an
// explicit null itself, with the typed decode error (review finding F1 on
// #41287: first_tab on a create-workspace reply).
namespace {
const std::string kMutationResult =
    R"("generation":"g","index":1,"key":"k","registry_id":"r","replayed":false,"workspace":1,"workspace_revision":1)";

cmux::raw::Result<cmux::raw::WorkspaceMutationResult> decode_mutation(const std::string& extra) {
    auto wire = cmux::raw::Json::parse("{" + kMutationResult + extra + "}");
    CHECK(wire);
    return cmux::raw::decode_value<cmux::raw::WorkspaceMutationResult>(wire.value());
}
}  // namespace

TEST("optional opaque JSON field that is not nullable rejects explicit null") {
    auto decoded = decode_mutation(R"(,"first_tab":null)");
    CHECK(!decoded);
    CHECK_EQ(decoded.error().code, cmux::raw::ErrorCode::decode);
}

TEST("optional opaque JSON field keeps absence and present values") {
    auto absent = decode_mutation("");
    CHECK(absent);
    CHECK(!absent.value().first_tab.has_value());

    auto present = decode_mutation(R"(,"first_tab":{"kind":"browser"})");
    CHECK(present);
    CHECK(present.value().first_tab.has_value());
}

TEST("required opaque JSON field that is not nullable rejects explicit null") {
    auto wire = cmux::raw::Json::parse(R"({"conversation":"c","participant":"p","item":null})");
    CHECK(wire);
    auto decoded = cmux::raw::decode_value<cmux::raw::ConversationDraftEvent>(wire.value());
    CHECK(!decoded);
    CHECK_EQ(decoded.error().code, cmux::raw::ErrorCode::decode);
}
