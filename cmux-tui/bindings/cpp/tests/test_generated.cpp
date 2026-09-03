#include "test.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <set>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>

#include "cmux/raw/client.hpp"

static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().identify()),
              cmux::raw::Result<cmux::raw::IdentifyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().subscribe_deltas()),
              cmux::raw::Result<cmux::raw::DeltaStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().attach_bytes(
                  std::declval<const cmux::raw::AttachSurfaceRequest&>())),
              cmux::raw::Result<cmux::raw::ByteStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().attach_render(
                  std::declval<const cmux::raw::AttachSurfaceRequest&>())),
              cmux::raw::Result<cmux::raw::RenderStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().attach_browser(
                  std::declval<const cmux::raw::AttachSurfaceRequest&>())),
              cmux::raw::Result<cmux::raw::BrowserStream>>);
static_assert(std::is_same_v<
              decltype(
                  std::declval<cmux::raw::Client&>().browser_frame_presented(
                      std::declval<
                          const cmux::raw::BrowserFramePresentedRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().browser_key_press(
                  std::declval<
                      const cmux::raw::BrowserKeyPressRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(
                  std::declval<cmux::raw::Client&>().browser_mouse_guarded(
                      std::declval<
                          const cmux::raw::BrowserMouseGuardedRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(
                  std::declval<cmux::raw::Client&>().browser_wheel_guarded(
                      std::declval<
                          const cmux::raw::BrowserWheelGuardedRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().clear_history(
                  std::declval<const cmux::raw::ClearHistoryRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().new_pane_right(
                  std::declval<const cmux::raw::NewPaneRightRequest&>())),
              cmux::raw::Result<cmux::raw::SurfaceResult>>);
static_assert(std::is_same_v<
              decltype(
                  std::declval<cmux::raw::Client&>().set_viewport_pane_width(
                      std::declval<
                          const cmux::raw::SetViewportPaneWidthRequest&>())),
              cmux::raw::Result<cmux::raw::EmptyResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().undo_layout(
                  std::declval<const cmux::raw::UndoLayoutRequest&>())),
              cmux::raw::Result<cmux::raw::LayoutUndoResult>>);
static_assert(
    std::variant_size_v<cmux::raw::LayoutUndoResult::Variant> == 2U);
static_assert(std::is_same_v<
              std::variant_alternative_t<
                  0, cmux::raw::LayoutUndoResult::Variant>,
              cmux::raw::LayoutUndoUndone>);
static_assert(std::is_same_v<
              std::variant_alternative_t<
                  1, cmux::raw::LayoutUndoResult::Variant>,
              cmux::raw::LayoutUndoConfirmationRequired>);
static_assert(!std::is_copy_constructible_v<cmux::raw::EventStream>);
static_assert(std::is_move_constructible_v<cmux::raw::EventStream>);

constexpr std::size_t kExpectedRawCommandCount = 104U;
constexpr std::array<std::string_view, 4> kViewportHistoryCommandNames{
    "clear-history",
    "new-pane-right",
    "set-viewport-pane-width",
    "undo-layout",
};
constexpr std::array<std::string_view, 4> kBrowserPointerCommandNames{
    "browser-frame-presented",
    "browser-key-press",
    "browser-mouse-guarded",
    "browser-wheel-guarded",
};

TEST("generated command and event metadata is exhaustive and unique") {
    const auto commands = cmux::raw::command_metadata();
    const auto events = cmux::raw::event_metadata();
    CHECK_EQ(commands.size(), kExpectedRawCommandCount);
    CHECK_EQ(events.size(), 47U);

    std::set<std::string_view> command_names;
    bool checked_attach_fields = false;
    for (const auto& command : commands) {
        CHECK(!command.name.empty());
        CHECK(!command.authority.empty());
        CHECK(command.since <= cmux::raw::kMuxProtocolVersion);
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
    for (const auto name : kViewportHistoryCommandNames) {
        CHECK(command_names.contains(name));
    }
    for (const auto name : kBrowserPointerCommandNames) {
        CHECK(command_names.contains(name));
    }

    std::set<std::string_view> event_names;
    for (const auto& event : events) {
        CHECK(!event.name.empty());
        CHECK(event.since <= cmux::raw::kMuxProtocolVersion);
        event_names.insert(event.name);
    }
    CHECK_EQ(event_names.size(), events.size());
}

TEST("generated guarded browser requests preserve exact fields") {
    constexpr auto frame_seq = std::numeric_limits<std::uint64_t>::max();

    cmux::raw::BrowserFramePresentedRequest presented;
    presented.frame_seq = frame_seq;
    presented.surface = cmux::raw::Id{7};
    auto encoded_presented = cmux::raw::encode_value(presented);
    CHECK(encoded_presented);
    CHECK_EQ(
        encoded_presented.value()
            .find("frame_seq")
            ->as_uint64()
            .value(),
        frame_seq);
    auto decoded_presented =
        cmux::raw::decode_value<cmux::raw::BrowserFramePresentedRequest>(
            encoded_presented.value());
    CHECK(decoded_presented);
    CHECK_EQ(decoded_presented.value(), presented);

    cmux::raw::BrowserKeyPressRequest key;
    key.code = "KeyA";
    key.key = "a";
    key.modifiers = 3;
    key.surface = cmux::raw::Id{7};
    key.text = cmux::raw::Field<std::string>("a");
    key.windows_virtual_key_code = 65;
    auto encoded_key = cmux::raw::encode_value(key);
    CHECK(encoded_key);
    auto decoded_key =
        cmux::raw::decode_value<cmux::raw::BrowserKeyPressRequest>(
            encoded_key.value());
    CHECK(decoded_key);
    CHECK_EQ(decoded_key.value(), key);

    cmux::raw::BrowserMouseGuardedRequest mouse;
    mouse.button = cmux::raw::Field<std::string>("left");
    mouse.click_count = cmux::raw::Field<std::uint32_t>(2);
    mouse.frame_seq = frame_seq;
    mouse.kind = cmux::raw::BrowserMouseGuardedRequestKind::down;
    mouse.surface = cmux::raw::Id{7};
    mouse.x_px = 12.5;
    mouse.y_px = 34.5;
    auto encoded_mouse = cmux::raw::encode_value(mouse);
    CHECK(encoded_mouse);
    CHECK_EQ(
        encoded_mouse.value().find("frame_seq")->as_uint64().value(),
        frame_seq);
    auto decoded_mouse =
        cmux::raw::decode_value<cmux::raw::BrowserMouseGuardedRequest>(
            encoded_mouse.value());
    CHECK(decoded_mouse);
    CHECK_EQ(decoded_mouse.value(), mouse);

    cmux::raw::BrowserWheelGuardedRequest wheel;
    wheel.delta_y_px = -120.25;
    wheel.frame_seq = frame_seq;
    wheel.surface = cmux::raw::Id{7};
    wheel.x_px = 640.5;
    wheel.y_px = 360.25;
    auto encoded_wheel = cmux::raw::encode_value(wheel);
    CHECK(encoded_wheel);
    CHECK_EQ(
        encoded_wheel.value().find("frame_seq")->as_uint64().value(),
        frame_seq);
    auto decoded_wheel =
        cmux::raw::decode_value<cmux::raw::BrowserWheelGuardedRequest>(
            encoded_wheel.value());
    CHECK(decoded_wheel);
    CHECK_EQ(decoded_wheel.value(), wheel);
}

TEST("layout undo result variants round trip without losing their branch") {
    cmux::raw::LayoutUndoUndone undone;
    undone.confirmation_required = false;
    undone.revision = std::numeric_limits<std::uint64_t>::max();
    undone.screen = cmux::raw::Id{7};
    cmux::raw::LayoutUndoResult undone_result{
        cmux::raw::LayoutUndoResult::Variant(undone),
    };
    auto encoded_undone = cmux::raw::encode_value(undone_result);
    CHECK(encoded_undone);
    auto decoded_undone =
        cmux::raw::decode_value<cmux::raw::LayoutUndoResult>(
            encoded_undone.value());
    CHECK(decoded_undone);
    const auto* decoded_undone_value =
        std::get_if<cmux::raw::LayoutUndoUndone>(
            &decoded_undone.value().value);
    CHECK(decoded_undone_value != nullptr);
    CHECK_EQ(decoded_undone_value->revision, undone.revision);
    CHECK_EQ(decoded_undone_value->screen, undone.screen);

    cmux::raw::LayoutUndoConfirmationRequired confirmation;
    confirmation.closes_panes = {
        cmux::raw::Id{11},
        cmux::raw::Id{12},
    };
    confirmation.revision = 42;
    confirmation.screen = cmux::raw::Id{9};
    cmux::raw::LayoutUndoResult confirmation_result{
        cmux::raw::LayoutUndoResult::Variant(confirmation),
    };
    auto encoded_confirmation =
        cmux::raw::encode_value(confirmation_result);
    CHECK(encoded_confirmation);
    auto decoded_confirmation =
        cmux::raw::decode_value<cmux::raw::LayoutUndoResult>(
            encoded_confirmation.value());
    CHECK(decoded_confirmation);
    const auto* decoded_confirmation_value =
        std::get_if<cmux::raw::LayoutUndoConfirmationRequired>(
            &decoded_confirmation.value().value);
    CHECK(decoded_confirmation_value != nullptr);
    CHECK_EQ(
        decoded_confirmation_value->closes_panes,
        confirmation.closes_panes);
    CHECK_EQ(
        decoded_confirmation_value->revision,
        confirmation.revision);
    CHECK_EQ(decoded_confirmation_value->screen, confirmation.screen);
}

TEST("generated uint64 aliases retain values above JavaScript's safe range") {
    const cmux::raw::Id identifier{std::numeric_limits<std::uint64_t>::max()};
    auto encoded = cmux::raw::encode_value(identifier);
    CHECK(encoded);
    CHECK_EQ(
        encoded.value().as_uint64().value(),
        std::numeric_limits<std::uint64_t>::max());
    auto decoded = cmux::raw::decode_value<cmux::raw::Id>(encoded.value());
    CHECK(decoded);
    CHECK_EQ(decoded.value(), identifier);
}

TEST("generated optional nullable request fields preserve absent and null") {
    cmux::raw::SetDefaultColorsRequest request;
    auto absent = cmux::raw::encode_value(request);
    CHECK(absent);
    CHECK(absent.value().find("fg") == nullptr);

    request.fg = cmux::raw::Field<cmux::raw::ColorHex>::null();
    auto explicit_null = cmux::raw::encode_value(request);
    CHECK(explicit_null);
    CHECK(explicit_null.value().find("fg") != nullptr);
    CHECK(explicit_null.value().find("fg")->is_null());
}

TEST("terminal placement rejects legacy shapes and round trips typed lifecycle") {
    auto legacy = cmux::raw::Json::parse(
        R"({"surface":1,"terminal_id":null,"terminal_incarnation":null,"pane":2,"screen":3,"workspace":4,"key":"legacy","lifecycle":null,"terminal_revision":5,"replayed":false,"registry_id":"registry","generation":"boot"})");
    CHECK(legacy);
    auto legacy_placement =
        cmux::raw::decode_value<cmux::raw::TerminalPlacement>(legacy.value());
    CHECK(!legacy_placement);
    CHECK_EQ(legacy_placement.error().code, cmux::raw::ErrorCode::decode);

    auto current = cmux::raw::Json::parse(
        R"({"already_exited":false,"exit":null,"surface":1,"terminal_id":"terminal","terminal_incarnation":"incarnation","pane":2,"screen":3,"workspace":4,"key":"current","lifecycle":"running","terminal_revision":6,"replayed":true,"registry_id":"registry","generation":"boot"})");
    CHECK(current);
    auto current_placement =
        cmux::raw::decode_value<cmux::raw::TerminalPlacement>(current.value());
    CHECK(current_placement);
    CHECK_EQ(
        current_placement.value().lifecycle,
        cmux::raw::TerminalLifecycle::running);
    auto current_round_trip = cmux::raw::encode_value(current_placement.value());
    CHECK(current_round_trip);
    CHECK(current_round_trip.value().find("exit")->is_null());
    CHECK_EQ(
        current_round_trip.value().find("lifecycle")->as_string().value(),
        std::string_view("running"));

    current_placement.value().lifecycle =
        static_cast<cmux::raw::TerminalLifecycle>(999);
    auto invalid = cmux::raw::encode_value(current_placement.value());
    CHECK(!invalid);
    CHECK_EQ(invalid.error().code, cmux::raw::ErrorCode::invalid_argument);
}

TEST("known events decode to typed variants") {
    auto wire = cmux::raw::Json::parse(R"({"event":"config-reload-requested"})");
    CHECK(wire);
    auto event = cmux::raw::decode_value<cmux::raw::Event>(wire.value());
    CHECK(event);
    CHECK(std::holds_alternative<cmux::raw::ConfigReloadRequestedEvent>(event.value().value));
    CHECK_EQ(event.value().name(), std::string_view("config-reload-requested"));
}

TEST("unknown events retain their name and entire JSON object") {
    auto wire = cmux::raw::Json::parse(
        R"({"event":"future-protocol-event","id":18446744073709551615,"nested":{"x":1}})");
    CHECK(wire);
    auto event = cmux::raw::decode_value<cmux::raw::Event>(wire.value());
    CHECK(event);
    const auto* unknown = std::get_if<cmux::raw::UnknownEvent>(&event.value().value);
    CHECK(unknown != nullptr);
    CHECK_EQ(unknown->name, std::string("future-protocol-event"));
    CHECK_EQ(unknown->raw, wire.value());
    auto encoded = cmux::raw::encode_value(event.value());
    CHECK(encoded);
    CHECK_EQ(encoded.value(), wire.value());
}

TEST("recursive tagged layout models round trip through shared ownership") {
    cmux::raw::LayoutSplit split;
    split.dir = cmux::raw::SplitDirection::right;
    split.ratio = 0.5F;
    split.a = std::make_shared<cmux::raw::Layout>(
        cmux::raw::Layout{cmux::raw::Layout::Variant(cmux::raw::LayoutLeaf{cmux::raw::Id{1}})});
    split.b = std::make_shared<cmux::raw::Layout>(
        cmux::raw::Layout{cmux::raw::Layout::Variant(
            cmux::raw::LayoutStack{cmux::raw::Id{2}, {cmux::raw::Id{2}, cmux::raw::Id{3}}})});
    cmux::raw::Layout layout{cmux::raw::Layout::Variant(std::move(split))};
    auto encoded = cmux::raw::encode_value(layout);
    CHECK(encoded);
    auto decoded = cmux::raw::decode_value<cmux::raw::Layout>(encoded.value());
    CHECK(decoded);
    CHECK(std::holds_alternative<cmux::raw::LayoutSplit>(decoded.value().value));
}
