#include "test.hpp"

#include <cstdint>
#include <limits>
#include <set>
#include <string>
#include <type_traits>
#include <utility>

#include "cmux/client.hpp"

static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().identify()),
              cmux::Result<cmux::IdentifyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().subscribe_deltas()),
              cmux::Result<cmux::DeltaStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().attach_bytes(
                  std::declval<const cmux::AttachSurfaceRequest&>())),
              cmux::Result<cmux::ByteStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().attach_render(
                  std::declval<const cmux::AttachSurfaceRequest&>())),
              cmux::Result<cmux::RenderStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Client&>().attach_browser(
                  std::declval<const cmux::AttachSurfaceRequest&>())),
              cmux::Result<cmux::BrowserStream>>);
static_assert(!std::is_copy_constructible_v<cmux::EventStream>);
static_assert(std::is_move_constructible_v<cmux::EventStream>);

TEST("generated command and event metadata is exhaustive and unique") {
    const auto commands = cmux::command_metadata();
    const auto events = cmux::event_metadata();
    CHECK_EQ(commands.size(), 83U);
    CHECK_EQ(events.size(), 44U);

    std::set<std::string_view> command_names;
    bool checked_attach_fields = false;
    for (const auto& command : commands) {
        CHECK(!command.name.empty());
        CHECK(!command.authority.empty());
        CHECK(command.since <= cmux::kMuxProtocolVersion);
        command_names.insert(command.name);
        if (command.name == "attach-surface") {
            CHECK_EQ(command.field_requirements.size(), 3U);
            bool mode_since = false;
            bool cols_capability = false;
            for (const auto& field : command.field_requirements) {
                mode_since =
                    mode_since || (field.name == "mode" && field.since == 7U);
                cols_capability =
                    cols_capability ||
                    (field.name == "cols" &&
                     field.capability == "attach-initial-size");
            }
            CHECK(mode_since);
            CHECK(cols_capability);
            checked_attach_fields = true;
        }
    }
    CHECK_EQ(command_names.size(), commands.size());
    CHECK(checked_attach_fields);

    std::set<std::string_view> event_names;
    for (const auto& event : events) {
        CHECK(!event.name.empty());
        CHECK(event.since <= cmux::kMuxProtocolVersion);
        event_names.insert(event.name);
    }
    CHECK_EQ(event_names.size(), events.size());
}

TEST("generated uint64 aliases retain values above JavaScript's safe range") {
    const cmux::Id identifier{std::numeric_limits<std::uint64_t>::max()};
    auto encoded = cmux::encode_value(identifier);
    CHECK(encoded);
    CHECK_EQ(
        encoded.value().as_uint64().value(),
        std::numeric_limits<std::uint64_t>::max());
    auto decoded = cmux::decode_value<cmux::Id>(encoded.value());
    CHECK(decoded);
    CHECK_EQ(decoded.value(), identifier);
}

TEST("generated optional nullable request fields preserve absent and null") {
    cmux::SetDefaultColorsRequest request;
    auto absent = cmux::encode_value(request);
    CHECK(absent);
    CHECK(absent.value().find("fg") == nullptr);

    request.fg = cmux::Field<cmux::ColorHex>::null();
    auto explicit_null = cmux::encode_value(request);
    CHECK(explicit_null);
    CHECK(explicit_null.value().find("fg") != nullptr);
    CHECK(explicit_null.value().find("fg")->is_null());
}

TEST("required nullable literal fields round trip null and their literal value") {
    auto legacy = cmux::Json::parse(
        R"({"surface":1,"terminal_id":null,"terminal_incarnation":null,"pane":2,"screen":3,"workspace":4,"key":"legacy","lifecycle":null,"terminal_revision":5,"replayed":false,"registry_id":"registry","generation":"boot"})");
    CHECK(legacy);
    auto legacy_placement =
        cmux::decode_value<cmux::TerminalPlacement>(legacy.value());
    CHECK(legacy_placement);
    CHECK(!legacy_placement.value().lifecycle.has_value());
    auto legacy_round_trip = cmux::encode_value(legacy_placement.value());
    CHECK(legacy_round_trip);
    CHECK(legacy_round_trip.value().find("lifecycle")->is_null());

    auto current = cmux::Json::parse(
        R"({"surface":1,"terminal_id":"terminal","terminal_incarnation":"incarnation","pane":2,"screen":3,"workspace":4,"key":"current","lifecycle":"running","terminal_revision":6,"replayed":true,"registry_id":"registry","generation":"boot"})");
    CHECK(current);
    auto current_placement =
        cmux::decode_value<cmux::TerminalPlacement>(current.value());
    CHECK(current_placement);
    CHECK_EQ(
        current_placement.value().lifecycle,
        std::optional<std::string>("running"));
    auto current_round_trip = cmux::encode_value(current_placement.value());
    CHECK(current_round_trip);
    CHECK_EQ(
        current_round_trip.value().find("lifecycle")->as_string().value(),
        std::string_view("running"));

    current_placement.value().lifecycle = "exited";
    auto invalid = cmux::encode_value(current_placement.value());
    CHECK(!invalid);
    CHECK_EQ(invalid.error().code, cmux::ErrorCode::invalid_argument);
}

TEST("known events decode to typed variants") {
    auto wire = cmux::Json::parse(R"({"event":"config-reload-requested"})");
    CHECK(wire);
    auto event = cmux::decode_value<cmux::Event>(wire.value());
    CHECK(event);
    CHECK(std::holds_alternative<cmux::ConfigReloadRequestedEvent>(event.value().value));
    CHECK_EQ(event.value().name(), std::string_view("config-reload-requested"));
}

TEST("unknown events retain their name and entire JSON object") {
    auto wire = cmux::Json::parse(
        R"({"event":"future-protocol-event","id":18446744073709551615,"nested":{"x":1}})");
    CHECK(wire);
    auto event = cmux::decode_value<cmux::Event>(wire.value());
    CHECK(event);
    const auto* unknown = std::get_if<cmux::UnknownEvent>(&event.value().value);
    CHECK(unknown != nullptr);
    CHECK_EQ(unknown->name, std::string("future-protocol-event"));
    CHECK_EQ(unknown->raw, wire.value());
    auto encoded = cmux::encode_value(event.value());
    CHECK(encoded);
    CHECK_EQ(encoded.value(), wire.value());
}

TEST("recursive tagged layout models round trip through shared ownership") {
    cmux::LayoutSplit split;
    split.dir = cmux::SplitDirection::right;
    split.ratio = 0.5F;
    split.a = std::make_shared<cmux::Layout>(
        cmux::Layout{cmux::Layout::Variant(cmux::LayoutLeaf{cmux::Id{1}})});
    split.b = std::make_shared<cmux::Layout>(
        cmux::Layout{cmux::Layout::Variant(
            cmux::LayoutStack{cmux::Id{2}, {cmux::Id{2}, cmux::Id{3}}})});
    cmux::Layout layout{cmux::Layout::Variant(std::move(split))};
    auto encoded = cmux::encode_value(layout);
    CHECK(encoded);
    auto decoded = cmux::decode_value<cmux::Layout>(encoded.value());
    CHECK(decoded);
    CHECK(std::holds_alternative<cmux::LayoutSplit>(decoded.value().value));
}
