#include "cmux/resource.hpp"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <limits>
#include <string_view>
#include <utility>

#include "cmux/base64.hpp"

namespace cmux {
namespace {

struct DecodeFailure {
    Error error;
};

[[noreturn]] void fail(std::string message) {
    throw DecodeFailure(make_error(ErrorCode::decode, std::move(message)));
}

template <typename T, typename Function>
Result<T> guarded(Function&& function) {
    try {
        return std::forward<Function>(function)();
    } catch (DecodeFailure& failure) {
        return std::move(failure.error);
    }
}

const Json::Object& exact_object(
    const Json& value,
    std::initializer_list<std::string_view> allowed,
    std::initializer_list<std::string_view> required,
    std::string_view context) {
    auto object = value.as_object();
    if (!object) {
        fail(std::string(context) + " must be an object");
    }
    for (const auto& [key, item] : *object.value()) {
        static_cast<void>(item);
        if (std::find(allowed.begin(), allowed.end(), key) == allowed.end()) {
            fail(
                std::string(context) + " contains unknown field '" + key +
                "'");
        }
    }
    for (const auto field : required) {
        if (!object.value()->contains(field)) {
            fail(
                std::string(context) + " is missing required field '" +
                std::string(field) + "'");
        }
    }
    return *object.value();
}

const Json& field(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto found = object.find(name);
    if (found == object.end()) {
        fail(
            std::string(context) + " is missing required field '" +
            std::string(name) + "'");
    }
    return found->second;
}

std::string string_value(const Json& value, std::string_view context) {
    auto text = value.as_string();
    if (!text) {
        fail(std::string(context) + " must be a string");
    }
    return std::string(text.value());
}

std::string bounded_string(
    const Json& value,
    std::string_view context,
    std::size_t minimum,
    std::size_t maximum) {
    auto text = string_value(value, context);
    if (text.size() < minimum || text.size() > maximum) {
        fail(std::string(context) + " length is outside protocol bounds");
    }
    return text;
}

bool bool_value(const Json& value, std::string_view context) {
    auto boolean = value.as_bool();
    if (!boolean) {
        fail(std::string(context) + " must be a boolean");
    }
    return boolean.value();
}

std::uint64_t uint_value(
    const Json& value,
    std::uint64_t maximum,
    std::string_view context,
    bool positive = false) {
    auto integer = value.as_uint64();
    if (!integer || integer.value() > maximum ||
        (positive && integer.value() == 0)) {
        fail(std::string(context) + " is outside its unsigned integer bounds");
    }
    return integer.value();
}

std::int64_t int_value(
    const Json& value,
    std::int64_t minimum,
    std::int64_t maximum,
    std::string_view context) {
    auto integer = value.as_int64();
    if (!integer || integer.value() < minimum ||
        integer.value() > maximum) {
        fail(std::string(context) + " is outside its signed integer bounds");
    }
    return integer.value();
}

std::uint64_t decimal_value(
    const Json& value,
    std::string_view context) {
    auto text = value.as_string();
    if (!text || text.value().empty() ||
        (text.value().size() > 1U && text.value().front() == '0')) {
        fail(std::string(context) + " must be a canonical decimal string");
    }
    std::uint64_t parsed = 0;
    for (const char byte : text.value()) {
        if (byte < '0' || byte > '9') {
            fail(std::string(context) + " must be a canonical decimal string");
        }
        const auto digit = static_cast<std::uint64_t>(byte - '0');
        if (parsed >
            (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) {
            fail(std::string(context) + " exceeds uint64");
        }
        parsed = parsed * 10U + digit;
    }
    return parsed;
}

template <typename Id>
Id id_value(const Json& value, std::string_view context) {
    auto parsed = Id::parse(string_value(value, context));
    if (!parsed) {
        fail(std::string(context) + ": " + parsed.error().message);
    }
    return std::move(parsed).value();
}

template <typename T, typename Parser>
std::vector<T> array_value(
    const Json& value,
    std::string_view context,
    Parser&& parser) {
    auto array = value.as_array();
    if (!array) {
        fail(std::string(context) + " must be an array");
    }
    std::vector<T> result;
    result.reserve(array.value()->size());
    for (const auto& item : *array.value()) {
        result.push_back(parser(item));
    }
    return result;
}

std::optional<std::string> optional_string(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto found = object.find(name);
    if (found == object.end()) {
        return std::nullopt;
    }
    if (found->second.is_null()) {
        fail(std::string(context) + " must not be null");
    }
    return string_value(found->second, context);
}

std::optional<std::string> required_nullable_string(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto& value = field(object, name, context);
    if (value.is_null()) {
        return std::nullopt;
    }
    return string_value(value, context);
}

std::optional<std::string> optional_nullable_string(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto found = object.find(name);
    if (found == object.end() || found->second.is_null()) {
        return std::nullopt;
    }
    return string_value(found->second, context);
}

template <typename Id>
std::optional<Id> optional_id_value(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto found = object.find(name);
    if (found == object.end()) {
        return std::nullopt;
    }
    if (found->second.is_null()) {
        fail(std::string(context) + " must not be null");
    }
    return id_value<Id>(found->second, context);
}

template <typename Id>
std::optional<Id> required_nullable_id_value(
    const Json::Object& object,
    std::string_view name,
    std::string_view context) {
    const auto& value = field(object, name, context);
    if (value.is_null()) {
        return std::nullopt;
    }
    return id_value<Id>(value, context);
}

Json::Object extra_value(
    const Json::Object& object,
    std::string_view context) {
    const auto found = object.find("extra");
    if (found == object.end()) {
        return {};
    }
    auto extra = found->second.as_object();
    if (!extra) {
        fail(std::string(context) + " extra must be an object");
    }
    return *extra.value();
}

template <typename Enum>
Enum enum_value(
    const Json& value,
    std::initializer_list<std::pair<std::string_view, Enum>> values,
    std::string_view context) {
    const auto text = string_value(value, context);
    for (const auto& [wire, decoded] : values) {
        if (text == wire) {
            return decoded;
        }
    }
    fail(std::string(context) + " has an unrecognized value");
}

Cursor parse_cursor_model(const Json& value) {
    const auto& object = exact_object(
        value,
        {"generation", "revision"},
        {"generation", "revision"},
        "cursor");
    return {
        bounded_string(
            field(object, "generation", "cursor"),
            "cursor generation",
            1,
            128),
        decimal_value(field(object, "revision", "cursor"), "cursor revision"),
    };
}

Size parse_size(const Json& value) {
    const auto& object = exact_object(
        value, {"cols", "rows"}, {"cols", "rows"}, "size");
    return {
        static_cast<std::uint16_t>(uint_value(
            field(object, "cols", "size"),
            std::numeric_limits<std::uint16_t>::max(),
            "size cols",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "rows", "size"),
            std::numeric_limits<std::uint16_t>::max(),
            "size rows",
            true)),
    };
}

PixelSize parse_pixel_size(const Json& value) {
    const auto& object = exact_object(
        value,
        {"width_px", "height_px"},
        {"width_px", "height_px"},
        "pixel size");
    return {
        static_cast<std::uint32_t>(uint_value(
            field(object, "width_px", "pixel size"),
            std::numeric_limits<std::uint32_t>::max(),
            "pixel width",
            true)),
        static_cast<std::uint32_t>(uint_value(
            field(object, "height_px", "pixel size"),
            std::numeric_limits<std::uint32_t>::max(),
            "pixel height",
            true)),
    };
}

LayoutNode parse_layout_node(const Json& value);

LayoutColumn parse_layout_column(const Json& value) {
    const auto& object = exact_object(
        value,
        {"column_id", "width", "root"},
        {"column_id", "width", "root"},
        "layout column");
    auto width = field(object, "width", "layout column").as_double();
    if (!width || !std::isfinite(width.value()) ||
        width.value() < 0.1 || width.value() > 1.0) {
        fail("layout column width must be between 0.1 and 1");
    }
    return {
        id_value<SplitId>(
            field(object, "column_id", "layout column"),
            "layout column_id"),
        width.value(),
        std::make_shared<LayoutNode>(
            parse_layout_node(field(object, "root", "layout column"))),
    };
}

LayoutNode parse_layout_node(const Json& value) {
    auto raw = value.as_object();
    if (!raw) {
        fail("layout node must be an object");
    }
    const auto kind = string_value(
        field(*raw.value(), "kind", "layout node"), "layout kind");
    if (kind == "leaf") {
        const auto& object = exact_object(
            value,
            {"kind", "pane_id", "tab_ids", "active_tab_id"},
            {"kind", "pane_id", "tab_ids"},
            "layout leaf");
        return LayoutNode{LayoutLeaf{
            id_value<PaneId>(
                field(object, "pane_id", "layout leaf"),
                "layout pane_id"),
            array_value<TabId>(
                field(object, "tab_ids", "layout leaf"),
                "layout tab_ids",
                [](const Json& item) {
                    return id_value<TabId>(item, "layout tab_id");
                }),
            optional_id_value<TabId>(
                object, "active_tab_id", "layout active_tab_id"),
        }};
    }
    if (kind == "split") {
        const auto& object = exact_object(
            value,
            {"kind", "split_id", "direction", "ratio", "first", "second"},
            {"kind", "split_id", "direction", "ratio", "first", "second"},
            "layout split");
        auto ratio = field(object, "ratio", "layout split").as_double();
        if (!ratio || !std::isfinite(ratio.value()) ||
            ratio.value() <= 0.0 || ratio.value() >= 1.0) {
            fail("layout split ratio must be between 0 and 1");
        }
        return LayoutNode{LayoutSplit{
            id_value<SplitId>(
                field(object, "split_id", "layout split"),
                "layout split_id"),
            enum_value<LayoutDirection>(
                field(object, "direction", "layout split"),
                {
                    {"horizontal", LayoutDirection::horizontal},
                    {"vertical", LayoutDirection::vertical},
                },
                "layout direction"),
            ratio.value(),
            std::make_shared<LayoutNode>(
                parse_layout_node(field(object, "first", "layout split"))),
            std::make_shared<LayoutNode>(
                parse_layout_node(field(object, "second", "layout split"))),
        }};
    }
    if (kind == "stack") {
        const auto& object = exact_object(
            value,
            {"kind", "pane_ids", "expanded_pane_id"},
            {"kind", "pane_ids", "expanded_pane_id"},
            "layout stack");
        auto pane_ids = array_value<PaneId>(
            field(object, "pane_ids", "layout stack"),
            "layout pane_ids",
            [](const Json& item) {
                return id_value<PaneId>(item, "layout pane_id");
            });
        auto expanded = id_value<PaneId>(
            field(object, "expanded_pane_id", "layout stack"),
            "layout expanded_pane_id");
        if (pane_ids.empty() ||
            std::find(pane_ids.begin(), pane_ids.end(), expanded) ==
                pane_ids.end()) {
            fail("layout stack must contain its expanded pane");
        }
        return LayoutNode{LayoutStack{
            std::move(pane_ids),
            std::move(expanded),
        }};
    }
    if (kind == "viewport") {
        const auto& object = exact_object(
            value,
            {"kind", "base_width", "columns"},
            {"kind", "base_width", "columns"},
            "layout viewport");
        auto width = field(
            object, "base_width", "layout viewport").as_double();
        if (!width || !std::isfinite(width.value()) ||
            width.value() < 0.1 || width.value() > 1.0) {
            fail("layout viewport base_width must be between 0.1 and 1");
        }
        auto columns = array_value<LayoutColumn>(
            field(object, "columns", "layout viewport"),
            "layout columns",
            parse_layout_column);
        if (columns.empty()) {
            fail("layout viewport columns must not be empty");
        }
        return LayoutNode{LayoutViewport{
            width.value(),
            std::move(columns),
        }};
    }
    fail("layout node kind is unrecognized");
}

LayoutDocument parse_layout_document(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "version",
            "screen_id",
            "active_pane_id",
            "zoomed_pane_id",
            "root",
            "extra",
        },
        {
            "version",
            "screen_id",
            "active_pane_id",
            "zoomed_pane_id",
            "root",
        },
        "layout document");
    std::optional<PaneId> zoomed;
    const auto& raw_zoomed = field(
        object, "zoomed_pane_id", "layout document");
    if (!raw_zoomed.is_null()) {
        zoomed = id_value<PaneId>(raw_zoomed, "layout zoomed_pane_id");
    }
    return {
        static_cast<std::uint32_t>(uint_value(
            field(object, "version", "layout document"),
            std::numeric_limits<std::uint32_t>::max(),
            "layout version")),
        id_value<ScreenId>(
            field(object, "screen_id", "layout document"),
            "layout screen_id"),
        id_value<PaneId>(
            field(object, "active_pane_id", "layout document"),
            "layout active_pane_id"),
        std::move(zoomed),
        parse_layout_node(field(object, "root", "layout document")),
        extra_value(object, "layout document"),
    };
}

RenderCursor parse_render_cursor(const Json& value) {
    const auto& object = exact_object(
        value,
        {"x", "y", "style", "blink", "visible", "color"},
        {"x", "y", "style", "blink", "visible", "color"},
        "render cursor");
    auto color = required_nullable_string(object, "color", "render color");
    return {
        static_cast<std::uint16_t>(uint_value(
            field(object, "x", "render cursor"),
            std::numeric_limits<std::uint16_t>::max(),
            "cursor x")),
        static_cast<std::uint16_t>(uint_value(
            field(object, "y", "render cursor"),
            std::numeric_limits<std::uint16_t>::max(),
            "cursor y")),
        enum_value<RenderCursorStyle>(
            field(object, "style", "render cursor"),
            {
                {"block", RenderCursorStyle::block},
                {"underline", RenderCursorStyle::underline},
                {"bar", RenderCursorStyle::bar},
            },
            "render cursor style"),
        bool_value(field(object, "blink", "render cursor"), "cursor blink"),
        bool_value(
            field(object, "visible", "render cursor"), "cursor visible"),
        std::move(color),
    };
}

RenderRun parse_render_run(const Json& value) {
    const auto& object = exact_object(
        value,
        {"text", "fg", "bg", "attrs", "underline", "width_hint"},
        {"text", "fg", "bg", "attrs"},
        "render run");
    std::optional<RenderUnderline> underline;
    if (const auto found = object.find("underline");
        found != object.end()) {
        if (found->second.is_null()) {
            fail("render underline must not be null");
        }
        underline = enum_value<RenderUnderline>(
            found->second,
            {
                {"single", RenderUnderline::single},
                {"double", RenderUnderline::double_line},
                {"curly", RenderUnderline::curly},
                {"dotted", RenderUnderline::dotted},
                {"dashed", RenderUnderline::dashed},
            },
            "render underline");
    }
    std::optional<std::uint16_t> width_hint;
    if (const auto found = object.find("width_hint");
        found != object.end()) {
        if (found->second.is_null()) {
            fail("render width_hint must not be null");
        }
        width_hint = static_cast<std::uint16_t>(uint_value(
            found->second,
            std::numeric_limits<std::uint16_t>::max(),
            "render width_hint"));
    }
    return {
        string_value(field(object, "text", "render run"), "render text"),
        required_nullable_string(object, "fg", "render fg"),
        required_nullable_string(object, "bg", "render bg"),
        static_cast<std::uint32_t>(uint_value(
            field(object, "attrs", "render run"),
            std::numeric_limits<std::uint32_t>::max(),
            "render attrs")),
        underline,
        width_hint,
    };
}

RenderRow parse_render_row(const Json& value) {
    const auto& object = exact_object(
        value, {"row", "runs"}, {"row", "runs"}, "render row");
    return {
        static_cast<std::uint16_t>(uint_value(
            field(object, "row", "render row"),
            std::numeric_limits<std::uint16_t>::max(),
            "render row index")),
        array_value<RenderRun>(
            field(object, "runs", "render row"),
            "render runs",
            parse_render_run),
    };
}

RenderSnapshot parse_render_snapshot(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "size",
            "cursor",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        },
        {
            "size",
            "cursor",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        },
        "render snapshot");
    auto decoded = RenderSnapshot{
        parse_size(field(object, "size", "render snapshot")),
        parse_render_cursor(field(object, "cursor", "render snapshot")),
        string_value(
            field(object, "default_fg", "render snapshot"),
            "render default_fg"),
        string_value(
            field(object, "default_bg", "render snapshot"),
            "render default_bg"),
        static_cast<std::uint32_t>(uint_value(
            field(object, "scrollback_rows", "render snapshot"),
            std::numeric_limits<std::uint32_t>::max(),
            "render scrollback_rows")),
        array_value<RenderRow>(
            field(object, "rows", "render snapshot"),
            "render rows",
            parse_render_row),
    };
    if (decoded.rows.size() != decoded.size.rows) {
        fail("render snapshot row count must match size rows");
    }
    return decoded;
}

RenderPatch parse_render_patch(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "cursor",
            "full_reset",
            "size",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        },
        {"cursor", "full_reset", "rows"},
        "render patch");
    std::optional<Size> size;
    if (const auto found = object.find("size"); found != object.end()) {
        if (found->second.is_null()) {
            fail("render patch size must not be null");
        }
        size = parse_size(found->second);
    }
    std::optional<std::uint32_t> scrollback;
    if (const auto found = object.find("scrollback_rows");
        found != object.end()) {
        if (found->second.is_null()) {
            fail("render patch scrollback_rows must not be null");
        }
        scrollback = static_cast<std::uint32_t>(uint_value(
            found->second,
            std::numeric_limits<std::uint32_t>::max(),
            "render patch scrollback_rows"));
    }
    auto decoded = RenderPatch{
        parse_render_cursor(field(object, "cursor", "render patch")),
        bool_value(
            field(object, "full_reset", "render patch"),
            "render full_reset"),
        size,
        optional_string(object, "default_fg", "render default_fg"),
        optional_string(object, "default_bg", "render default_bg"),
        scrollback,
        array_value<RenderRow>(
            field(object, "rows", "render patch"),
            "render patch rows",
            parse_render_row),
    };
    if (decoded.size && !decoded.full_reset) {
        fail("render resize patch requires full_reset");
    }
    if (decoded.size && decoded.rows.size() != decoded.size->rows) {
        fail("render resize patch row count must match size rows");
    }
    return decoded;
}

RenderScroll parse_render_scroll(const Json& value) {
    const auto& object = exact_object(
        value,
        {"offset", "at_bottom"},
        {"offset", "at_bottom"},
        "render scroll");
    return {
        decimal_value(
            field(object, "offset", "render scroll"),
            "render scroll offset"),
        bool_value(
            field(object, "at_bottom", "render scroll"),
            "render at_bottom"),
    };
}

MachineSnapshot parse_machine(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "name",
            "origin",
            "status",
            "connectable",
            "deleted",
            "recoverable",
            "extra",
        },
        {
            "id",
            "name",
            "origin",
            "status",
            "connectable",
            "deleted",
            "recoverable",
        },
        "machine snapshot");
    return {
        id_value<MachineId>(field(object, "id", "machine"), "machine id"),
        string_value(field(object, "name", "machine"), "machine name"),
        enum_value<MachineOrigin>(
            field(object, "origin", "machine"),
            {
                {"local", MachineOrigin::local},
            },
            "machine origin"),
        enum_value<MachineStatus>(
            field(object, "status", "machine"),
            {
                {"running", MachineStatus::running},
                {"connecting", MachineStatus::connecting},
                {"sleeping", MachineStatus::sleeping},
                {"stopped", MachineStatus::stopped},
                {"unavailable", MachineStatus::unavailable},
            },
            "machine status"),
        bool_value(
            field(object, "connectable", "machine"), "machine connectable"),
        bool_value(field(object, "deleted", "machine"), "machine deleted"),
        bool_value(
            field(object, "recoverable", "machine"), "machine recoverable"),
        extra_value(object, "machine snapshot"),
    };
}

SessionSnapshot parse_session(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "machine_id",
            "name",
            "generation",
            "revision",
            "connected",
            "extra",
        },
        {"id", "machine_id", "generation", "revision", "connected"},
        "session snapshot");
    return {
        id_value<SessionId>(field(object, "id", "session"), "session id"),
        id_value<MachineId>(
            field(object, "machine_id", "session"), "session machine_id"),
        optional_string(object, "name", "session name"),
        bounded_string(
            field(object, "generation", "session"),
            "session generation",
            1,
            128),
        decimal_value(
            field(object, "revision", "session"), "session revision"),
        bool_value(
            field(object, "connected", "session"), "session connected"),
        extra_value(object, "session snapshot"),
    };
}

WorkspaceSnapshot parse_workspace(const Json& value) {
    const auto& object = exact_object(
        value,
        {"id", "session_id", "name", "index", "focused", "extra"},
        {"id", "session_id", "name", "index", "focused"},
        "workspace snapshot");
    return {
        id_value<WorkspaceId>(
            field(object, "id", "workspace"), "workspace id"),
        id_value<SessionId>(
            field(object, "session_id", "workspace"),
            "workspace session_id"),
        string_value(
            field(object, "name", "workspace"), "workspace name"),
        static_cast<std::uint32_t>(uint_value(
            field(object, "index", "workspace"),
            std::numeric_limits<std::uint32_t>::max(),
            "workspace index")),
        bool_value(
            field(object, "focused", "workspace"), "workspace focused"),
        extra_value(object, "workspace snapshot"),
    };
}

ScreenSnapshot parse_screen(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "workspace_id",
            "name",
            "index",
            "focused",
            "layout",
            "extra",
        },
        {"id", "workspace_id", "name", "index", "focused", "layout"},
        "screen snapshot");
    return {
        id_value<ScreenId>(field(object, "id", "screen"), "screen id"),
        id_value<WorkspaceId>(
            field(object, "workspace_id", "screen"),
            "screen workspace_id"),
        required_nullable_string(object, "name", "screen name"),
        static_cast<std::uint32_t>(uint_value(
            field(object, "index", "screen"),
            std::numeric_limits<std::uint32_t>::max(),
            "screen index")),
        bool_value(field(object, "focused", "screen"), "screen focused"),
        parse_layout_document(field(object, "layout", "screen")),
        extra_value(object, "screen snapshot"),
    };
}

PaneSnapshot parse_pane(const Json& value) {
    const auto& object = exact_object(
        value,
        {"id", "screen_id", "name", "focused", "zoomed", "extra"},
        {"id", "screen_id", "name", "focused", "zoomed"},
        "pane snapshot");
    return {
        id_value<PaneId>(field(object, "id", "pane"), "pane id"),
        id_value<ScreenId>(
            field(object, "screen_id", "pane"), "pane screen_id"),
        required_nullable_string(object, "name", "pane name"),
        bool_value(field(object, "focused", "pane"), "pane focused"),
        bool_value(field(object, "zoomed", "pane"), "pane zoomed"),
        extra_value(object, "pane snapshot"),
    };
}

TabSnapshot parse_tab(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "pane_id",
            "name",
            "index",
            "focused",
            "content_kind",
            "content_id",
            "extra",
        },
        {
            "id",
            "pane_id",
            "name",
            "index",
            "focused",
            "content_kind",
            "content_id",
        },
        "tab snapshot");
    const auto kind = string_value(
        field(object, "content_kind", "tab"), "tab content_kind");
    TabContentId content;
    if (kind == "terminal") {
        content = id_value<TerminalId>(
            field(object, "content_id", "tab"), "tab terminal content_id");
    } else if (kind == "browser") {
        content = id_value<BrowserId>(
            field(object, "content_id", "tab"), "tab browser content_id");
    } else {
        fail("tab content_kind is unrecognized");
    }
    return {
        id_value<TabId>(field(object, "id", "tab"), "tab id"),
        id_value<PaneId>(field(object, "pane_id", "tab"), "tab pane_id"),
        required_nullable_string(object, "name", "tab name"),
        static_cast<std::uint32_t>(uint_value(
            field(object, "index", "tab"),
            std::numeric_limits<std::uint32_t>::max(),
            "tab index")),
        bool_value(field(object, "focused", "tab"), "tab focused"),
        std::move(content),
        extra_value(object, "tab snapshot"),
    };
}

TerminalExitOutcome parse_terminal_exit_outcome(const Json& value) {
    auto raw = value.as_object();
    if (!raw) {
        fail("terminal exit outcome must be an object");
    }
    const auto kind = string_value(
        field(*raw.value(), "kind", "terminal exit outcome"),
        "terminal exit outcome kind");
    if (kind == "exit") {
        const auto& object = exact_object(
            value, {"kind", "code"}, {"kind", "code"}, "terminal exit code");
        return TerminalExitCode{static_cast<std::int32_t>(int_value(
            field(object, "code", "terminal exit code"),
            std::numeric_limits<std::int32_t>::min(),
            std::numeric_limits<std::int32_t>::max(),
            "terminal exit code"))};
    }
    if (kind == "signal") {
        const auto& object = exact_object(
            value,
            {"kind", "signal", "core_dumped"},
            {"kind", "signal", "core_dumped"},
            "terminal exit signal");
        return TerminalExitSignal{
            static_cast<std::int32_t>(int_value(
                field(object, "signal", "terminal exit signal"),
                1,
                std::numeric_limits<std::int32_t>::max(),
                "terminal exit signal")),
            bool_value(
                field(object, "core_dumped", "terminal exit signal"),
                "terminal exit core_dumped"),
        };
    }
    if (kind == "unknown") {
        const auto& object = exact_object(
            value,
            {"kind", "reason"},
            {"kind", "reason"},
            "terminal exit unknown");
        return TerminalExitUnknown{bounded_string(
            field(object, "reason", "terminal exit unknown"),
            "terminal exit reason",
            1,
            std::numeric_limits<std::size_t>::max())};
    }
    fail("terminal exit outcome kind is unrecognized");
}

TerminalExit parse_terminal_exit(const Json& value) {
    const auto& object = exact_object(
        value,
        {"outcome", "exited_at", "revision"},
        {"outcome", "exited_at", "revision"},
        "terminal exit");
    return {
        parse_terminal_exit_outcome(
            field(object, "outcome", "terminal exit")),
        decimal_value(
            field(object, "exited_at", "terminal exit"),
            "terminal exited_at"),
        decimal_value(
            field(object, "revision", "terminal exit"),
            "terminal exit revision"),
    };
}

TerminalSnapshot parse_terminal(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "tab_id",
            "tab_ids",
            "title",
            "cwd",
            "cols",
            "rows",
            "running",
            "lifecycle",
            "exit",
            "extra",
        },
        {
            "id",
            "title",
            "cols",
            "rows",
            "running",
            "lifecycle",
        },
        "terminal snapshot");
    const auto lifecycle = enum_value<TerminalLifecycle>(
        field(object, "lifecycle", "terminal"),
        {
            {"launching", TerminalLifecycle::launching},
            {"running", TerminalLifecycle::running},
            {"exited", TerminalLifecycle::exited},
        },
        "terminal lifecycle");
    const auto running =
        bool_value(field(object, "running", "terminal"), "terminal running");
    std::optional<TerminalExit> exit;
    if (const auto found = object.find("exit"); found != object.end()) {
        exit = parse_terminal_exit(found->second);
    }
    if (running != (lifecycle == TerminalLifecycle::running) ||
        exit.has_value() != (lifecycle == TerminalLifecycle::exited)) {
        fail("terminal running, lifecycle, and exit fields are inconsistent");
    }
    const auto legacy_field = object.find("tab_id");
    const bool has_legacy_tab_id = legacy_field != object.end();
    std::optional<TabId> legacy_tab_id;
    if (has_legacy_tab_id && !legacy_field->second.is_null()) {
        legacy_tab_id = id_value<TabId>(
            legacy_field->second, "terminal tab_id");
    }
    const auto tab_ids_field = object.find("tab_ids");
    std::vector<TabId> tab_ids;
    if (tab_ids_field != object.end()) {
        tab_ids = array_value<TabId>(
            tab_ids_field->second,
            "terminal tab_ids",
            [](const Json& item) {
                return id_value<TabId>(item, "terminal tab_id");
            });
    } else if (has_legacy_tab_id) {
        if (legacy_tab_id.has_value()) {
            tab_ids.push_back(legacy_tab_id.value());
        }
    } else {
        fail("terminal snapshot requires tab_ids or tab_id");
    }
    if (has_legacy_tab_id &&
        (legacy_tab_id.has_value() != !tab_ids.empty() ||
         (legacy_tab_id.has_value() &&
          legacy_tab_id.value() != tab_ids.front()))) {
        fail("terminal tab_id must be the first tab_ids item");
    }
    return {
        id_value<TerminalId>(
            field(object, "id", "terminal"), "terminal id"),
        legacy_tab_id,
        std::move(tab_ids),
        string_value(
            field(object, "title", "terminal"), "terminal title"),
        optional_string(object, "cwd", "terminal cwd"),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cols", "terminal"),
            std::numeric_limits<std::uint16_t>::max(),
            "terminal cols",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "rows", "terminal"),
            std::numeric_limits<std::uint16_t>::max(),
            "terminal rows",
            true)),
        running,
        lifecycle,
        std::move(exit),
        extra_value(object, "terminal snapshot"),
    };
}

BrowserSnapshot parse_browser(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "tab_id",
            "url",
            "title",
            "loading",
            "source",
            "status",
            "error",
            "frames_stalled",
            "size",
            "extra",
        },
        {
            "id",
            "tab_id",
            "url",
            "title",
            "loading",
            "source",
            "status",
            "error",
            "frames_stalled",
            "size",
        },
        "browser snapshot");
    return {
        id_value<BrowserId>(field(object, "id", "browser"), "browser id"),
        id_value<TabId>(
            field(object, "tab_id", "browser"), "browser tab_id"),
        string_value(field(object, "url", "browser"), "browser url"),
        string_value(field(object, "title", "browser"), "browser title"),
        bool_value(field(object, "loading", "browser"), "browser loading"),
        enum_value<BrowserSource>(
            field(object, "source", "browser"),
            {
                {"external", BrowserSource::external},
                {"launched", BrowserSource::launched},
            },
            "browser source"),
        enum_value<BrowserStatus>(
            field(object, "status", "browser"),
            {
                {"starting", BrowserStatus::starting},
                {"live", BrowserStatus::live},
                {"failed", BrowserStatus::failed},
            },
            "browser status"),
        required_nullable_string(object, "error", "browser error"),
        bool_value(
            field(object, "frames_stalled", "browser"),
            "browser frames_stalled"),
        parse_size(field(object, "size", "browser")),
        extra_value(object, "browser snapshot"),
    };
}

ClientTerminalSize parse_client_size(const Json& value) {
    const auto& object = exact_object(
        value,
        {"terminal_id", "cols", "rows", "participating"},
        {"terminal_id", "cols", "rows", "participating"},
        "client terminal size");
    std::optional<std::uint16_t> cols;
    std::optional<std::uint16_t> rows;
    const auto& raw_cols = field(object, "cols", "client terminal size");
    const auto& raw_rows = field(object, "rows", "client terminal size");
    if (raw_cols.is_null() != raw_rows.is_null()) {
        fail("client terminal cols and rows must both be null or present");
    }
    if (!raw_cols.is_null()) {
        cols = static_cast<std::uint16_t>(uint_value(
            raw_cols,
            std::numeric_limits<std::uint16_t>::max(),
            "client terminal cols",
            true));
        rows = static_cast<std::uint16_t>(uint_value(
            raw_rows,
            std::numeric_limits<std::uint16_t>::max(),
            "client terminal rows",
            true));
    }
    return {
        id_value<TerminalId>(
            field(object, "terminal_id", "client terminal size"),
            "client terminal_id"),
        cols,
        rows,
        bool_value(
            field(object, "participating", "client terminal size"),
            "client terminal participating"),
    };
}

ClientSnapshot parse_client(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "session_id",
            "name",
            "client_kind",
            "transport",
            "connected_seconds",
            "attached_terminal_ids",
            "sizes",
            "self",
            "extra",
        },
        {
            "id",
            "session_id",
            "name",
            "client_kind",
            "transport",
            "connected_seconds",
            "attached_terminal_ids",
            "sizes",
            "self",
        },
        "client snapshot");
    return {
        id_value<ConnectedClientId>(
            field(object, "id", "client"), "client id"),
        id_value<SessionId>(
            field(object, "session_id", "client"), "client session_id"),
        required_nullable_string(object, "name", "client name"),
        required_nullable_string(
            object, "client_kind", "client client_kind"),
        enum_value<ClientTransport>(
            field(object, "transport", "client"),
            {
                {"unix", ClientTransport::unix_socket},
                {"websocket", ClientTransport::websocket},
            },
            "client transport"),
        decimal_value(
            field(object, "connected_seconds", "client"),
            "client connected_seconds"),
        array_value<TerminalId>(
            field(object, "attached_terminal_ids", "client"),
            "client attached_terminal_ids",
            [](const Json& item) {
                return id_value<TerminalId>(
                    item, "client attached terminal_id");
            }),
        array_value<ClientTerminalSize>(
            field(object, "sizes", "client"),
            "client sizes",
            parse_client_size),
        bool_value(field(object, "self", "client"), "client self"),
        extra_value(object, "client snapshot"),
    };
}

NotificationSnapshot parse_notification(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "session_id",
            "title",
            "body",
            "level",
            "terminal_id",
            "created_at_ms",
            "unread",
            "extra",
        },
        {
            "id",
            "session_id",
            "title",
            "body",
            "level",
            "created_at_ms",
            "unread",
        },
        "notification snapshot");
    return {
        id_value<NotificationId>(
            field(object, "id", "notification"), "notification id"),
        id_value<SessionId>(
            field(object, "session_id", "notification"),
            "notification session_id"),
        string_value(
            field(object, "title", "notification"), "notification title"),
        string_value(
            field(object, "body", "notification"), "notification body"),
        enum_value<NotificationLevel>(
            field(object, "level", "notification"),
            {
                {"info", NotificationLevel::info},
                {"warning", NotificationLevel::warning},
                {"error", NotificationLevel::error},
            },
            "notification level"),
        optional_id_value<TerminalId>(
            object, "terminal_id", "notification terminal_id"),
        decimal_value(
            field(object, "created_at_ms", "notification"),
            "notification created_at_ms"),
        bool_value(
            field(object, "unread", "notification"), "notification unread"),
        extra_value(object, "notification snapshot"),
    };
}

AgentSnapshot parse_agent(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "session_id",
            "terminal_id",
            "state",
            "source",
            "updated_at_ms",
            "source_session",
            "extra",
        },
        {
            "id",
            "session_id",
            "terminal_id",
            "state",
            "source",
            "updated_at_ms",
            "source_session",
        },
        "agent snapshot");
    return {
        id_value<AgentId>(field(object, "id", "agent"), "agent id"),
        id_value<SessionId>(
            field(object, "session_id", "agent"), "agent session_id"),
        id_value<TerminalId>(
            field(object, "terminal_id", "agent"), "agent terminal_id"),
        enum_value<AgentState>(
            field(object, "state", "agent"),
            {
                {"working", AgentState::working},
                {"blocked", AgentState::blocked},
                {"idle", AgentState::idle},
                {"done", AgentState::done},
                {"unknown", AgentState::unknown},
            },
            "agent state"),
        enum_value<AgentSource>(
            field(object, "source", "agent"),
            {
                {"hook", AgentSource::hook},
                {"socket", AgentSource::socket},
                {"detected", AgentSource::detected},
            },
            "agent source"),
        decimal_value(
            field(object, "updated_at_ms", "agent"), "agent updated_at_ms"),
        required_nullable_string(
            object, "source_session", "agent source_session"),
        extra_value(object, "agent snapshot"),
    };
}

PairingRequestSnapshot parse_pairing(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id",
            "session_id",
            "peer",
            "code",
            "expires_in_seconds",
            "status",
            "extra",
        },
        {
            "id",
            "session_id",
            "peer",
            "code",
            "expires_in_seconds",
            "status",
        },
        "pairing request snapshot");
    return {
        id_value<PairingRequestId>(
            field(object, "id", "pairing request"), "pairing request id"),
        id_value<SessionId>(
            field(object, "session_id", "pairing request"),
            "pairing session_id"),
        string_value(
            field(object, "peer", "pairing request"), "pairing peer"),
        SensitiveString(string_value(
            field(object, "code", "pairing request"), "pairing code")),
        decimal_value(
            field(object, "expires_in_seconds", "pairing request"),
            "pairing expires_in_seconds"),
        enum_value<PairingStatus>(
            field(object, "status", "pairing request"),
            {
                {"pending", PairingStatus::pending},
                {"accepted", PairingStatus::accepted},
                {"rejected", PairingStatus::rejected},
            },
            "pairing status"),
        extra_value(object, "pairing request snapshot"),
    };
}

FrontendProjectionSnapshot parse_projection(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "id", "session_id", "frontend_id", "window_id", "generation",
            "projection", "projection_revision", "extra",
        },
        {
            "id", "session_id", "frontend_id", "window_id", "generation",
            "projection", "projection_revision",
        },
        "frontend projection snapshot");
    return {
        id_value<FrontendProjectionId>(
            field(object, "id", "projection"), "projection id"),
        id_value<SessionId>(
            field(object, "session_id", "projection"),
            "projection session_id"),
        string_value(
            field(object, "frontend_id", "projection"),
            "projection frontend_id"),
        string_value(
            field(object, "window_id", "projection"),
            "projection window_id"),
        string_value(
            field(object, "generation", "projection"),
            "projection generation"),
        field(object, "projection", "projection"),
        decimal_value(
            field(object, "projection_revision", "projection"),
            "projection revision"),
        extra_value(object, "frontend projection snapshot"),
    };
}

SidebarViewSnapshot parse_sidebar(const Json& value) {
    const auto& object = exact_object(
        value,
        {"id", "session_id", "cols", "rows", "running", "extra"},
        {"id", "session_id", "cols", "rows", "running"},
        "sidebar view snapshot");
    return {
        id_value<SidebarViewId>(
            field(object, "id", "sidebar view"), "sidebar view id"),
        id_value<SessionId>(
            field(object, "session_id", "sidebar view"),
            "sidebar session_id"),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cols", "sidebar view"),
            std::numeric_limits<std::uint16_t>::max(),
            "sidebar cols",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "rows", "sidebar view"),
            std::numeric_limits<std::uint16_t>::max(),
            "sidebar rows",
            true)),
        bool_value(
            field(object, "running", "sidebar view"), "sidebar running"),
        extra_value(object, "sidebar view snapshot"),
    };
}

ResourceSnapshot parse_resource_snapshot(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "machine",
            "session",
            "workspaces",
            "screens",
            "panes",
            "tabs",
            "terminals",
            "browsers",
            "clients",
            "notifications",
            "agents",
            "frontend_projections",
            "sidebar_views",
            "cursor",
            "extra",
        },
        {
            "machine",
            "session",
            "workspaces",
            "screens",
            "panes",
            "tabs",
            "terminals",
            "browsers",
            "clients",
            "notifications",
            "agents",
            "frontend_projections",
            "sidebar_views",
            "cursor",
        },
        "resource snapshot");
    auto result = ResourceSnapshot{
        parse_machine(field(object, "machine", "resource snapshot")),
        parse_session(field(object, "session", "resource snapshot")),
        array_value<WorkspaceSnapshot>(
            field(object, "workspaces", "resource snapshot"),
            "resource workspaces",
            parse_workspace),
        array_value<ScreenSnapshot>(
            field(object, "screens", "resource snapshot"),
            "resource screens",
            parse_screen),
        array_value<PaneSnapshot>(
            field(object, "panes", "resource snapshot"),
            "resource panes",
            parse_pane),
        array_value<TabSnapshot>(
            field(object, "tabs", "resource snapshot"),
            "resource tabs",
            parse_tab),
        array_value<TerminalSnapshot>(
            field(object, "terminals", "resource snapshot"),
            "resource terminals",
            parse_terminal),
        array_value<BrowserSnapshot>(
            field(object, "browsers", "resource snapshot"),
            "resource browsers",
            parse_browser),
        array_value<ClientSnapshot>(
            field(object, "clients", "resource snapshot"),
            "resource clients",
            parse_client),
        array_value<NotificationSnapshot>(
            field(object, "notifications", "resource snapshot"),
            "resource notifications",
            parse_notification),
        array_value<AgentSnapshot>(
            field(object, "agents", "resource snapshot"),
            "resource agents",
            parse_agent),
        array_value<FrontendProjectionSnapshot>(
            field(object, "frontend_projections", "resource snapshot"),
            "resource frontend projections",
            parse_projection),
        array_value<SidebarViewSnapshot>(
            field(object, "sidebar_views", "resource snapshot"),
            "resource sidebar views",
            parse_sidebar),
        parse_cursor_model(field(object, "cursor", "resource snapshot")),
        extra_value(object, "resource snapshot"),
    };
    if (result.machine.id != result.session.machine_id) {
        fail("resource snapshot session does not belong to machine");
    }
    return result;
}

ResourceKind parse_resource_kind(const Json& value) {
    return enum_value<ResourceKind>(
        value,
        {
            {"machine", ResourceKind::machine},
            {"session", ResourceKind::session},
            {"workspace", ResourceKind::workspace},
            {"screen", ResourceKind::screen},
            {"pane", ResourceKind::pane},
            {"tab", ResourceKind::tab},
            {"terminal", ResourceKind::terminal},
            {"browser", ResourceKind::browser},
            {"client", ResourceKind::client},
            {"notification", ResourceKind::notification},
            {"agent", ResourceKind::agent},
            {"pairing_request", ResourceKind::pairing_request},
            {
                "frontend_projection",
                ResourceKind::frontend_projection,
            },
            {"sidebar_view", ResourceKind::sidebar_view},
        },
        "resource kind");
}

ResourceChangeId parse_resource_id(
    ResourceKind kind,
    const Json& value) {
    switch (kind) {
        case ResourceKind::machine:
            return id_value<MachineId>(value, "resource machine id");
        case ResourceKind::session:
            return id_value<SessionId>(value, "resource session id");
        case ResourceKind::workspace:
            return id_value<WorkspaceId>(value, "resource workspace id");
        case ResourceKind::screen:
            return id_value<ScreenId>(value, "resource screen id");
        case ResourceKind::pane:
            return id_value<PaneId>(value, "resource pane id");
        case ResourceKind::tab:
            return id_value<TabId>(value, "resource tab id");
        case ResourceKind::terminal:
            return id_value<TerminalId>(value, "resource terminal id");
        case ResourceKind::browser:
            return id_value<BrowserId>(value, "resource browser id");
        case ResourceKind::client:
            return id_value<ConnectedClientId>(value, "resource client id");
        case ResourceKind::notification:
            return id_value<NotificationId>(
                value, "resource notification id");
        case ResourceKind::agent:
            return id_value<AgentId>(value, "resource agent id");
        case ResourceKind::pairing_request:
            return id_value<PairingRequestId>(
                value, "resource pairing_request id");
        case ResourceKind::frontend_projection:
            return id_value<FrontendProjectionId>(
                value, "resource frontend_projection id");
        case ResourceKind::sidebar_view:
            return id_value<SidebarViewId>(
                value, "resource sidebar_view id");
    }
    fail("resource kind is unrecognized");
}

ResourceEntitySnapshot parse_resource_entity(
    ResourceKind kind,
    const Json& value) {
    switch (kind) {
        case ResourceKind::machine:
            return parse_machine(value);
        case ResourceKind::session:
            return parse_session(value);
        case ResourceKind::workspace:
            return parse_workspace(value);
        case ResourceKind::screen:
            return parse_screen(value);
        case ResourceKind::pane:
            return parse_pane(value);
        case ResourceKind::tab:
            return parse_tab(value);
        case ResourceKind::terminal:
            return parse_terminal(value);
        case ResourceKind::browser:
            return parse_browser(value);
        case ResourceKind::client:
            return parse_client(value);
        case ResourceKind::notification:
            return parse_notification(value);
        case ResourceKind::agent:
            return parse_agent(value);
        case ResourceKind::pairing_request:
            return parse_pairing(value);
        case ResourceKind::frontend_projection:
            return parse_projection(value);
        case ResourceKind::sidebar_view:
            return parse_sidebar(value);
    }
    fail("resource kind is unrecognized");
}

ResourceChange parse_resource_change(const Json& value) {
    auto raw = value.as_object();
    if (!raw) {
        fail("resource change must be an object");
    }
    const auto kind = bounded_string(
        field(*raw.value(), "kind", "resource change"),
        "resource change kind",
        1,
        std::numeric_limits<std::size_t>::max());
    if (kind != "upsert" && kind != "delete") {
        return Unknown{kind, value};
    }
    const bool upsert = kind == "upsert";
    const auto& object = upsert
        ? exact_object(
              value,
              {"kind", "sequence", "resource", "id", "value"},
              {"kind", "sequence", "resource", "id", "value"},
              "resource upsert")
        : exact_object(
              value,
              {"kind", "sequence", "resource", "id"},
              {"kind", "sequence", "resource", "id"},
              "resource delete");
    const auto resource = parse_resource_kind(
        field(object, "resource", "resource change"));
    const auto sequence = static_cast<std::uint32_t>(uint_value(
        field(object, "sequence", "resource change"),
        std::numeric_limits<std::uint32_t>::max(),
        "resource sequence"));
    auto id = parse_resource_id(
        resource, field(object, "id", "resource change"));
    if (!upsert) {
        return ResourceDelete{sequence, resource, std::move(id)};
    }
    return ResourceUpsert{
        sequence,
        resource,
        std::move(id),
        parse_resource_entity(
            resource, field(object, "value", "resource upsert")),
    };
}

ConfirmationRequiredDetails parse_confirmation_required_details(
    const Json& value) {
    const auto& object = exact_object(
        value,
        {"confirmation_token", "revision", "closes_panes"},
        {"confirmation_token", "revision", "closes_panes"},
        "confirmation required details");
    auto closes_panes = array_value<PaneId>(
        field(object, "closes_panes", "confirmation required details"),
        "confirmation closes_panes",
        [](const Json& item) {
            return id_value<PaneId>(
                item, "confirmation closes_panes item");
        });
    if (closes_panes.empty()) {
        fail("confirmation closes_panes must not be empty");
    }
    return {
        bounded_string(
            field(
                object,
                "confirmation_token",
                "confirmation required details"),
            "confirmation token",
            1,
            128),
        decimal_value(
            field(object, "revision", "confirmation required details"),
            "confirmation revision"),
        std::move(closes_panes),
    };
}

EmptyResult parse_empty(const Json& value) {
    exact_object(value, {}, {}, "empty result");
    return {};
}

PingResult parse_ping(const Json& value) {
    const auto& object = exact_object(
        value, {"alive", "cursor"}, {"alive", "cursor"}, "ping result");
    return {
        bool_value(field(object, "alive", "ping"), "ping alive"),
        parse_cursor_model(field(object, "cursor", "ping")),
    };
}

ShutdownResult parse_shutdown(const Json& value) {
    const auto& object = exact_object(
        value, {"accepted"}, {"accepted"}, "shutdown result");
    return {
        bool_value(
            field(object, "accepted", "shutdown"), "shutdown accepted"),
    };
}

ReloadConfigResult parse_reload_config(const Json& value) {
    const auto& object = exact_object(
        value,
        {"reloaded", "warnings"},
        {"reloaded", "warnings"},
        "reload config result");
    return {
        bool_value(
            field(object, "reloaded", "reload config"),
            "reload config reloaded"),
        array_value<std::string>(
            field(object, "warnings", "reload config"),
            "reload warnings",
            [](const Json& item) {
                return string_value(item, "reload warning");
            }),
    };
}

template <typename T, typename Parser>
NullableField<T> nullable_field(
    const Json::Object& object,
    std::string_view name,
    Parser&& parser) {
    const auto found = object.find(name);
    if (found == object.end()) {
        return {};
    }
    if (found->second.is_null()) {
        return {true, std::nullopt};
    }
    return {true, parser(found->second)};
}

TerminalDefaultsSnapshot parse_terminal_defaults(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "foreground",
            "background",
            "cursor",
            "selection_background",
            "selection_foreground",
            "cursor_style",
            "cursor_blink",
            "palette",
        },
        {},
        "terminal defaults snapshot");
    std::optional<std::map<std::string, std::string, std::less<>>> palette;
    if (const auto found = object.find("palette");
        found != object.end()) {
        auto values = found->second.as_object();
        if (!values) {
            fail("terminal defaults palette must be an object");
        }
        std::map<std::string, std::string, std::less<>> decoded;
        for (const auto& [key, item] : *values.value()) {
            decoded.emplace(key, string_value(item, "terminal palette color"));
        }
        palette = std::move(decoded);
    }
    const auto string_parser = [](const Json& item) {
        return string_value(item, "terminal default");
    };
    return {
        nullable_field<std::string>(
            object, "foreground", string_parser),
        nullable_field<std::string>(
            object, "background", string_parser),
        nullable_field<std::string>(object, "cursor", string_parser),
        nullable_field<std::string>(
            object, "selection_background", string_parser),
        nullable_field<std::string>(
            object, "selection_foreground", string_parser),
        nullable_field<std::string>(
            object, "cursor_style", string_parser),
        nullable_field<bool>(
            object,
            "cursor_blink",
            [](const Json& item) {
                return bool_value(item, "terminal cursor_blink");
            }),
        std::move(palette),
    };
}

PairingResolutionResult parse_pairing_resolution(const Json& value) {
    const auto& object = exact_object(
        value,
        {"pairing_request"},
        {"pairing_request"},
        "pairing resolution result");
    return {
        parse_pairing(
            field(object, "pairing_request", "pairing resolution")),
    };
}

PaneNeighborResult parse_pane_neighbor(const Json& value) {
    const auto& object = exact_object(
        value, {"pane"}, {}, "pane neighbor result");
    const auto found = object.find("pane");
    if (found == object.end() || found->second.is_null()) {
        return {};
    }
    return {parse_pane(found->second)};
}

TerminalScreenResult parse_terminal_screen(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "text",
            "cols",
            "rows",
            "cursor_row",
            "cursor_col",
            "cursor_visible",
            "extra",
        },
        {
            "text",
            "cols",
            "rows",
            "cursor_row",
            "cursor_col",
            "cursor_visible",
        },
        "terminal screen result");
    return {
        string_value(field(object, "text", "terminal screen"), "screen text"),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cols", "terminal screen"),
            std::numeric_limits<std::uint16_t>::max(),
            "screen cols",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "rows", "terminal screen"),
            std::numeric_limits<std::uint16_t>::max(),
            "screen rows",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cursor_row", "terminal screen"),
            std::numeric_limits<std::uint16_t>::max(),
            "screen cursor_row")),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cursor_col", "terminal screen"),
            std::numeric_limits<std::uint16_t>::max(),
            "screen cursor_col")),
        bool_value(
            field(object, "cursor_visible", "terminal screen"),
            "screen cursor_visible"),
        extra_value(object, "terminal screen"),
    };
}

TerminalStateResult parse_terminal_state(const Json& value) {
    const auto& object = exact_object(
        value,
        {"state_base64", "cols", "rows"},
        {"state_base64", "cols", "rows"},
        "terminal state result");
    auto decoded = base64_decode(string_value(
        field(object, "state_base64", "terminal state"),
        "terminal state_base64"));
    if (!decoded) {
        fail("terminal state_base64 is invalid");
    }
    return {
        std::move(decoded).value(),
        static_cast<std::uint16_t>(uint_value(
            field(object, "cols", "terminal state"),
            std::numeric_limits<std::uint16_t>::max(),
            "terminal state cols",
            true)),
        static_cast<std::uint16_t>(uint_value(
            field(object, "rows", "terminal state"),
            std::numeric_limits<std::uint16_t>::max(),
            "terminal state rows",
            true)),
    };
}

TerminalHistoryResult parse_terminal_history(const Json& value) {
    const auto& object = exact_object(
        value,
        {"start", "next", "rows"},
        {"start", "next", "rows"},
        "terminal history result");
    std::optional<std::uint64_t> next;
    const auto& raw_next = field(object, "next", "terminal history");
    if (!raw_next.is_null()) {
        next = decimal_value(raw_next, "terminal history next");
    }
    return {
        decimal_value(
            field(object, "start", "terminal history"),
            "terminal history start"),
        next,
        array_value<RenderRow>(
            field(object, "rows", "terminal history"),
            "terminal history rows",
            parse_render_row),
    };
}

TerminalWaitResult parse_terminal_wait(const Json& value) {
    const auto& object = exact_object(
        value,
        {"matched", "text"},
        {"matched", "text"},
        "terminal wait result");
    return {
        bool_value(
            field(object, "matched", "terminal wait"),
            "terminal wait matched"),
        string_value(
            field(object, "text", "terminal wait"), "terminal wait text"),
    };
}

TerminalCopyResult parse_terminal_copy(const Json& value) {
    const auto& object = exact_object(
        value, {"mode", "text"}, {"mode", "text"}, "terminal copy result");
    return {
        enum_value<TerminalCopyMode>(
            field(object, "mode", "terminal copy"),
            {
                {"screen", TerminalCopyMode::screen},
                {"selection", TerminalCopyMode::selection},
                {"scrollback", TerminalCopyMode::scrollback},
            },
            "terminal copy mode"),
        string_value(
            field(object, "text", "terminal copy"), "terminal copy text"),
    };
}

ProcessInfoResult parse_process_info(const Json& value) {
    const auto& object = exact_object(
        value,
        {"pid", "executable", "argv", "cwd", "foreground_cwd", "children"},
        {"pid", "argv", "children"},
        "process info result");
    return {
        static_cast<std::uint32_t>(uint_value(
            field(object, "pid", "process info"),
            std::numeric_limits<std::uint32_t>::max(),
            "process pid")),
        optional_string(object, "executable", "process executable"),
        array_value<std::string>(
            field(object, "argv", "process info"),
            "process argv",
            [](const Json& item) {
                return string_value(item, "process argv item");
            }),
        optional_string(object, "cwd", "process cwd"),
        optional_nullable_string(
            object, "foreground_cwd", "process foreground_cwd"),
        array_value<std::uint32_t>(
            field(object, "children", "process info"),
            "process children",
            [](const Json& item) {
                return static_cast<std::uint32_t>(uint_value(
                    item,
                    std::numeric_limits<std::uint32_t>::max(),
                    "process child pid"));
            }),
    };
}

RendererGrant parse_renderer_grant(const Json& value) {
    const auto& object = exact_object(
        value,
        {"endpoint", "terminal_id", "token", "rights", "ttl_ms"},
        {"endpoint", "terminal_id", "token", "rights", "ttl_ms"},
        "renderer grant result");
    auto rights = array_value<std::string>(
        field(object, "rights", "renderer grant"),
        "renderer rights",
        [](const Json& item) {
            return string_value(item, "renderer right");
        });
    if (rights.empty()) {
        fail("renderer rights must not be empty");
    }
    return {
        string_value(
            field(object, "endpoint", "renderer grant"),
            "renderer endpoint"),
        id_value<TerminalId>(
            field(object, "terminal_id", "renderer grant"),
            "renderer terminal_id"),
        SensitiveString(bounded_string(
            field(object, "token", "renderer grant"),
            "renderer token",
            1,
            std::numeric_limits<std::size_t>::max())),
        std::move(rights),
        static_cast<std::uint32_t>(uint_value(
            field(object, "ttl_ms", "renderer grant"),
            60000,
            "renderer ttl_ms",
            true)),
    };
}

CellPixelsResult parse_cell_pixels(const Json& value) {
    const auto& object = exact_object(
        value,
        {"width_px", "height_px", "resized_terminals", "failures"},
        {"width_px", "height_px", "resized_terminals", "failures"},
        "cell pixels result");
    auto raw_failures =
        field(object, "failures", "cell pixels result").as_object();
    if (!raw_failures) {
        fail("cell pixel failures must be an object");
    }
    std::map<std::string, std::string, std::less<>> failures;
    for (const auto& [key, item] : *raw_failures.value()) {
        failures.emplace(key, string_value(item, "cell pixel failure"));
    }
    return {
        static_cast<std::uint32_t>(uint_value(
            field(object, "width_px", "cell pixels result"),
            std::numeric_limits<std::uint32_t>::max(),
            "cell pixel width",
            true)),
        static_cast<std::uint32_t>(uint_value(
            field(object, "height_px", "cell pixels result"),
            std::numeric_limits<std::uint32_t>::max(),
            "cell pixel height",
            true)),
        array_value<TerminalId>(
            field(object, "resized_terminals", "cell pixels result"),
            "resized terminals",
            [](const Json& item) {
                return id_value<TerminalId>(item, "resized terminal id");
            }),
        std::move(failures),
    };
}

ViewerResizeResult parse_viewer_resize(const Json& value) {
    const auto& object = exact_object(
        value,
        {"accepted", "size", "outcome"},
        {"accepted", "size", "outcome"},
        "viewer resize result");
    return {
        bool_value(
            field(object, "accepted", "viewer resize"),
            "viewer resize accepted"),
        parse_size(field(object, "size", "viewer resize")),
        enum_value<ViewerResizeResult::Outcome>(
            field(object, "outcome", "viewer resize"),
            {
                {"applied", ViewerResizeResult::Outcome::applied},
                {"passive", ViewerResizeResult::Outcome::passive},
                {"superseded", ViewerResizeResult::Outcome::superseded},
            },
            "view attachment outcome"),
    };
}

BrowserViewerResizeResult parse_browser_viewer_resize(const Json& value) {
    const auto& object = exact_object(
        value,
        {"accepted", "size", "outcome"},
        {"accepted", "size", "outcome"},
        "browser viewer resize result");
    return {
        bool_value(
            field(object, "accepted", "browser viewer resize"),
            "browser viewer resize accepted"),
        parse_pixel_size(field(object, "size", "browser viewer resize")),
        enum_value<ViewerResizeResult::Outcome>(
            field(object, "outcome", "browser viewer resize"),
            {
                {"applied", ViewerResizeResult::Outcome::applied},
                {"passive", ViewerResizeResult::Outcome::passive},
                {"superseded", ViewerResizeResult::Outcome::superseded},
            },
            "view attachment outcome"),
    };
}

ViewerReleaseResult parse_viewer_release(const Json& value) {
    const auto& object = exact_object(
        value,
        {"outcome"},
        {"outcome"},
        "viewer release result");
    return {
        enum_value<ViewerResizeResult::Outcome>(
            field(object, "outcome", "viewer release"),
            {
                {"applied", ViewerResizeResult::Outcome::applied},
                {"passive", ViewerResizeResult::Outcome::passive},
                {"superseded", ViewerResizeResult::Outcome::superseded},
            },
            "view attachment outcome"),
    };
}

CreatedWorkspaceOnly parse_created_workspace(const Json& value) {
    const auto& object = exact_object(
        value,
        {"kind", "workspace_id"},
        {"kind", "workspace_id"},
        "created workspace path");
    if (string_value(field(object, "kind", "created path"), "created kind") !=
        "workspace") {
        fail("created workspace path kind is invalid");
    }
    return {id_value<WorkspaceId>(
        field(object, "workspace_id", "created workspace path"),
        "created workspace_id")};
}

CreatedTerminalPath parse_created_terminal(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "kind",
            "workspace_id",
            "screen_id",
            "pane_id",
            "tab_id",
            "terminal_id",
        },
        {
            "kind",
            "workspace_id",
            "screen_id",
            "pane_id",
            "tab_id",
            "terminal_id",
        },
        "created terminal path");
    if (string_value(field(object, "kind", "created path"), "created kind") !=
        "terminal") {
        fail("created terminal path kind is invalid");
    }
    return {
        id_value<WorkspaceId>(
            field(object, "workspace_id", "created terminal path"),
            "created workspace_id"),
        id_value<ScreenId>(
            field(object, "screen_id", "created terminal path"),
            "created screen_id"),
        id_value<PaneId>(
            field(object, "pane_id", "created terminal path"),
            "created pane_id"),
        id_value<TabId>(
            field(object, "tab_id", "created terminal path"),
            "created tab_id"),
        id_value<TerminalId>(
            field(object, "terminal_id", "created terminal path"),
            "created terminal_id"),
    };
}

CreatedBrowserPath parse_created_browser(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "kind",
            "workspace_id",
            "screen_id",
            "pane_id",
            "tab_id",
            "browser_id",
        },
        {
            "kind",
            "workspace_id",
            "screen_id",
            "pane_id",
            "tab_id",
            "browser_id",
        },
        "created browser path");
    if (string_value(field(object, "kind", "created path"), "created kind") !=
        "browser") {
        fail("created browser path kind is invalid");
    }
    return {
        id_value<WorkspaceId>(
            field(object, "workspace_id", "created browser path"),
            "created workspace_id"),
        id_value<ScreenId>(
            field(object, "screen_id", "created browser path"),
            "created screen_id"),
        id_value<PaneId>(
            field(object, "pane_id", "created browser path"),
            "created pane_id"),
        id_value<TabId>(
            field(object, "tab_id", "created browser path"),
            "created tab_id"),
        id_value<BrowserId>(
            field(object, "browser_id", "created browser path"),
            "created browser_id"),
    };
}

CreatedPath parse_created_path_model(const Json& value) {
    auto raw = value.as_object();
    if (!raw) {
        fail("created path must be an object");
    }
    const auto kind = string_value(
        field(*raw.value(), "kind", "created path"), "created path kind");
    if (kind == "workspace") {
        return parse_created_workspace(value);
    }
    if (kind == "terminal") {
        return parse_created_terminal(value);
    }
    if (kind == "browser") {
        return parse_created_browser(value);
    }
    fail("created path kind is unrecognized");
}

CreationResolution parse_creation_resolution(const Json& value) {
    const auto& object = exact_object(
        value,
        {
            "correlation_key",
            "state",
            "recovery",
            "operation",
            "idempotency_key",
            "created_path",
            "generation",
            "revision",
        },
        {"correlation_key", "state", "recovery"},
        "creation resolution");
    CreationResolution result{
        bounded_string(
            field(object, "correlation_key", "creation resolution"),
            "creation correlation_key",
            1,
            128),
        enum_value<CreationState>(
            field(object, "state", "creation resolution"),
            {
                {"pending", CreationState::pending},
                {"created", CreationState::created},
                {"not_applied", CreationState::not_applied},
                {"indeterminate", CreationState::indeterminate},
            },
            "creation state"),
        enum_value<CreationRecovery>(
            field(object, "recovery", "creation resolution"),
            {
                {
                    "retry_same_idempotency_key",
                    CreationRecovery::retry_same_idempotency_key,
                },
                {
                    "retry_new_idempotency_key",
                    CreationRecovery::retry_new_idempotency_key,
                },
                {"wait", CreationRecovery::wait},
                {"none", CreationRecovery::none},
                {"do_not_retry", CreationRecovery::do_not_retry},
            },
            "creation recovery"),
        optional_string(object, "operation", "creation operation"),
        optional_string(
            object, "idempotency_key", "creation idempotency_key"),
        {},
        {},
        {},
    };
    if (const auto found = object.find("created_path");
        found != object.end()) {
        result.created_path = parse_created_path_model(found->second);
    }
    result.generation =
        optional_string(object, "generation", "creation generation");
    if (const auto found = object.find("revision"); found != object.end()) {
        result.revision = decimal_value(found->second, "creation revision");
    }
    const bool created_complete =
        result.created_path && result.generation && result.revision;
    if ((result.state == CreationState::created &&
         (result.recovery != CreationRecovery::none || !created_complete)) ||
        (result.state == CreationState::pending &&
         result.recovery != CreationRecovery::wait) ||
        (result.state == CreationState::not_applied &&
         result.recovery != CreationRecovery::retry_same_idempotency_key &&
         result.recovery != CreationRecovery::retry_new_idempotency_key) ||
        (result.state == CreationState::indeterminate &&
         result.recovery != CreationRecovery::do_not_retry)) {
        fail("creation resolution state and recovery are inconsistent");
    }
    return result;
}

TerminalWaitExitResult parse_terminal_wait_exit(const Json& value) {
    auto raw = value.as_object();
    if (!raw) {
        fail("terminal wait-exit result must be an object");
    }
    const auto state = string_value(
        field(*raw.value(), "state", "terminal wait-exit"),
        "terminal wait-exit state");
    if (state == "pending") {
        const auto& object = exact_object(
            value,
            {"state", "terminal_id", "lifecycle", "revision"},
            {"state", "terminal_id", "lifecycle", "revision"},
            "terminal wait-exit pending");
        const auto lifecycle = string_value(
            field(object, "lifecycle", "terminal wait-exit pending"),
            "terminal lifecycle");
        if (lifecycle != "launching" && lifecycle != "running") {
            fail("pending terminal lifecycle is invalid");
        }
        return TerminalWaitExitPending{
            id_value<TerminalId>(
                field(object, "terminal_id", "terminal wait-exit pending"),
                "terminal wait-exit id"),
            lifecycle,
            decimal_value(
                field(object, "revision", "terminal wait-exit pending"),
                "terminal wait-exit revision"),
        };
    }
    if (state == "exited") {
        const auto& object = exact_object(
            value,
            {
                "state",
                "terminal_id",
                "lifecycle",
                "outcome",
                "exited_at",
                "revision",
            },
            {
                "state",
                "terminal_id",
                "lifecycle",
                "outcome",
                "exited_at",
                "revision",
            },
            "terminal wait-exit exited");
        if (string_value(
                field(object, "lifecycle", "terminal wait-exit exited"),
                "terminal lifecycle") != "exited") {
            fail("exited terminal lifecycle must be exited");
        }
        return TerminalWaitExitExited{
            id_value<TerminalId>(
                field(object, "terminal_id", "terminal wait-exit exited"),
                "terminal wait-exit id"),
            parse_terminal_exit_outcome(
                field(object, "outcome", "terminal wait-exit exited")),
            decimal_value(
                field(object, "exited_at", "terminal wait-exit exited"),
                "terminal exited_at"),
            decimal_value(
                field(object, "revision", "terminal wait-exit exited"),
                "terminal wait-exit revision"),
        };
    }
    fail("terminal wait-exit state is unrecognized");
}

bool cursors_equal(const Cursor& left, const Cursor& right) {
    return left.generation == right.generation &&
           left.revision == right.revision;
}

}  // namespace

namespace detail {

#define CMUX_DEFINE_DECODER(type, parser)                  \
    template <>                                            \
    Result<type> decode_value<type>(const Json& value) {   \
        return guarded<type>([&] { return parser(value); }); \
    }

CMUX_DEFINE_DECODER(CreatedPath, parse_created_path_model)
CMUX_DEFINE_DECODER(CreatedTerminalPath, parse_created_terminal)
CMUX_DEFINE_DECODER(CreatedBrowserPath, parse_created_browser)
CMUX_DEFINE_DECODER(EmptyResult, parse_empty)
CMUX_DEFINE_DECODER(
    ConfirmationRequiredDetails,
    parse_confirmation_required_details)
CMUX_DEFINE_DECODER(MachineSnapshot, parse_machine)
CMUX_DEFINE_DECODER(SessionSnapshot, parse_session)
CMUX_DEFINE_DECODER(WorkspaceSnapshot, parse_workspace)
CMUX_DEFINE_DECODER(ScreenSnapshot, parse_screen)
CMUX_DEFINE_DECODER(PaneSnapshot, parse_pane)
CMUX_DEFINE_DECODER(TabSnapshot, parse_tab)
CMUX_DEFINE_DECODER(TerminalSnapshot, parse_terminal)
CMUX_DEFINE_DECODER(BrowserSnapshot, parse_browser)
CMUX_DEFINE_DECODER(ClientSnapshot, parse_client)
CMUX_DEFINE_DECODER(NotificationSnapshot, parse_notification)
CMUX_DEFINE_DECODER(AgentSnapshot, parse_agent)
CMUX_DEFINE_DECODER(PairingRequestSnapshot, parse_pairing)
CMUX_DEFINE_DECODER(FrontendProjectionSnapshot, parse_projection)
CMUX_DEFINE_DECODER(SidebarViewSnapshot, parse_sidebar)
CMUX_DEFINE_DECODER(ResourceSnapshot, parse_resource_snapshot)
CMUX_DEFINE_DECODER(LayoutDocument, parse_layout_document)
CMUX_DEFINE_DECODER(ResourceChange, parse_resource_change)
CMUX_DEFINE_DECODER(PingResult, parse_ping)
CMUX_DEFINE_DECODER(ShutdownResult, parse_shutdown)
CMUX_DEFINE_DECODER(ReloadConfigResult, parse_reload_config)
CMUX_DEFINE_DECODER(TerminalDefaultsSnapshot, parse_terminal_defaults)
CMUX_DEFINE_DECODER(PairingResolutionResult, parse_pairing_resolution)
CMUX_DEFINE_DECODER(PaneNeighborResult, parse_pane_neighbor)
CMUX_DEFINE_DECODER(TerminalScreenResult, parse_terminal_screen)
CMUX_DEFINE_DECODER(TerminalStateResult, parse_terminal_state)
CMUX_DEFINE_DECODER(TerminalHistoryResult, parse_terminal_history)
CMUX_DEFINE_DECODER(TerminalWaitResult, parse_terminal_wait)
CMUX_DEFINE_DECODER(TerminalWaitExitResult, parse_terminal_wait_exit)
CMUX_DEFINE_DECODER(TerminalCopyResult, parse_terminal_copy)
CMUX_DEFINE_DECODER(ProcessInfoResult, parse_process_info)
CMUX_DEFINE_DECODER(RendererGrant, parse_renderer_grant)
CMUX_DEFINE_DECODER(CellPixelsResult, parse_cell_pixels)
CMUX_DEFINE_DECODER(ViewerResizeResult, parse_viewer_resize)
CMUX_DEFINE_DECODER(BrowserViewerResizeResult, parse_browser_viewer_resize)
CMUX_DEFINE_DECODER(ViewerReleaseResult, parse_viewer_release)
CMUX_DEFINE_DECODER(CreationResolution, parse_creation_resolution)

template <>
Result<JsonValue> decode_value<JsonValue>(const Json& value) {
    return value;
}

#undef CMUX_DEFINE_DECODER

Result<SessionEvent> decode_session_event(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    return guarded<SessionEvent>([&] {
        if (!envelope_cursor) {
            fail("session stream item requires an envelope cursor");
        }
        auto raw = value.as_object();
        if (!raw) {
            fail("session event must be an object");
        }
        const auto kind = bounded_string(
            field(*raw.value(), "kind", "session event"),
            "session event kind",
            1,
            std::numeric_limits<std::size_t>::max());
        if (kind == "snapshot") {
            const auto& object = exact_object(
                value,
                {"kind", "cursor", "reset_reason", "snapshot"},
                {"kind", "cursor", "snapshot"},
                "session snapshot item");
            auto cursor =
                parse_cursor_model(field(object, "cursor", "session snapshot"));
            if (!cursors_equal(cursor, *envelope_cursor)) {
                fail("session item cursor does not match envelope cursor");
            }
            std::optional<SessionResetReason> reset;
            if (const auto found = object.find("reset_reason");
                found != object.end()) {
                reset = enum_value<SessionResetReason>(
                    found->second,
                    {
                        {"initial", SessionResetReason::initial},
                        {
                            "generation_changed",
                            SessionResetReason::generation_changed,
                        },
                        {
                            "cursor_expired",
                            SessionResetReason::cursor_expired,
                        },
                    },
                    "session reset_reason");
            }
            return SessionEvent(SessionSnapshotEvent{
                std::move(cursor),
                reset,
                parse_resource_snapshot(
                    field(object, "snapshot", "session snapshot")),
            });
        }
        if (kind == "delta") {
            const auto& object = exact_object(
                value,
                {
                    "kind",
                    "cursor",
                    "previous_revision",
                    "revision",
                    "changes",
                },
                {
                    "kind",
                    "cursor",
                    "previous_revision",
                    "revision",
                    "changes",
                },
                "session delta item");
            auto cursor =
                parse_cursor_model(field(object, "cursor", "session delta"));
            if (!cursors_equal(cursor, *envelope_cursor)) {
                fail("session item cursor does not match envelope cursor");
            }
            return SessionEvent(SessionDeltaEvent{
                std::move(cursor),
                decimal_value(
                    field(object, "previous_revision", "session delta"),
                    "session previous_revision"),
                decimal_value(
                    field(object, "revision", "session delta"),
                    "session revision"),
                array_value<ResourceChange>(
                    field(object, "changes", "session delta"),
                    "session changes",
                    parse_resource_change),
            });
        }
        return SessionEvent(Unknown{kind, value});
    });
}

Result<SessionJournalRecord> decode_session_journal_record(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    return guarded<SessionJournalRecord>([&] {
        if (!envelope_cursor) {
            fail("journal stream item requires an envelope cursor");
        }
        const auto& object = exact_object(
            value,
            {
                "sequence", "event_id", "schema_version", "kind", "class", "replay",
                "occurred_at_ms", "committed_at_ms", "producer", "authority",
                "causation_id", "correlation_id", "causation_depth", "subjects",
                "sensitivity", "payload", "resource_revision", "previous_resource_revision",
            },
            {
                "sequence", "event_id", "schema_version", "kind", "class", "replay",
                "occurred_at_ms", "committed_at_ms", "producer", "authority",
                "causation_id", "correlation_id", "causation_depth", "subjects",
                "sensitivity", "payload", "resource_revision", "previous_resource_revision",
            },
            "session journal record");
        const auto sequence = decimal_value(
            field(object, "sequence", "session journal record"),
            "journal sequence");
        if (sequence != envelope_cursor->revision) {
            fail("journal sequence does not match envelope cursor");
        }
        const auto& producer_object = exact_object(
            field(object, "producer", "session journal record"),
            {"kind", "id"},
            {"kind", "id"},
            "journal producer");
        const auto& raw_authority = field(
            object, "authority", "session journal record");
        std::optional<JournalAuthority> authority;
        if (!raw_authority.is_null()) {
            const auto& authority_object = exact_object(
                raw_authority,
                {"principal_id", "lease_id", "generation", "role"},
                {"principal_id", "lease_id", "generation", "role"},
                "journal authority");
            authority = JournalAuthority{
                bounded_string(
                    field(authority_object, "principal_id", "journal authority"),
                    "journal principal_id", 1, 512),
                bounded_string(
                    field(authority_object, "lease_id", "journal authority"),
                    "journal lease_id", 1, 512),
                bounded_string(
                    field(authority_object, "generation", "journal authority"),
                    "journal generation", 1, 128),
                bounded_string(
                    field(authority_object, "role", "journal authority"),
                    "journal role", 1, 128),
            };
        }
        auto nullable_string = [&](std::string_view name) {
            auto result = required_nullable_string(object, name, "session journal record");
            if (result && (result->empty() || result->size() > 512U)) {
                fail(std::string(name) + " length is outside protocol bounds");
            }
            return result;
        };
        auto nullable_decimal = [&](std::string_view name) -> std::optional<std::uint64_t> {
            const auto& raw = field(object, name, "session journal record");
            if (raw.is_null()) {
                return std::nullopt;
            }
            return decimal_value(raw, name);
        };
        return SessionJournalRecord{
            sequence,
            bounded_string(
                field(object, "event_id", "session journal record"),
                "journal event_id", 1, 512),
            static_cast<std::uint32_t>(uint_value(
                field(object, "schema_version", "session journal record"),
                std::numeric_limits<std::uint32_t>::max(),
                "journal schema_version",
                true)),
            bounded_string(
                field(object, "kind", "session journal record"),
                "journal kind", 1, 128),
            enum_value<JournalClass>(
                field(object, "class", "session journal record"),
                {
                    {"state", JournalClass::state},
                    {"observation", JournalClass::observation},
                    {"effect", JournalClass::effect},
                    {"checkpoint", JournalClass::checkpoint},
                },
                "journal class"),
            enum_value<JournalReplayPolicy>(
                field(object, "replay", "session journal record"),
                {
                    {"required", JournalReplayPolicy::required},
                    {"advisory", JournalReplayPolicy::advisory},
                    {"never", JournalReplayPolicy::never},
                },
                "journal replay"),
            decimal_value(
                field(object, "occurred_at_ms", "session journal record"),
                "journal occurred_at_ms"),
            decimal_value(
                field(object, "committed_at_ms", "session journal record"),
                "journal committed_at_ms"),
            JournalProducer{
                bounded_string(
                    field(producer_object, "kind", "journal producer"),
                    "journal producer kind", 1, 128),
                bounded_string(
                    field(producer_object, "id", "journal producer"),
                    "journal producer id", 1, 512),
            },
            std::move(authority),
            nullable_string("causation_id"),
            nullable_string("correlation_id"),
            static_cast<std::uint16_t>(uint_value(
                field(object, "causation_depth", "session journal record"),
                std::numeric_limits<std::uint16_t>::max(),
                "journal causation_depth")),
            array_value<JournalSubject>(
                field(object, "subjects", "session journal record"),
                "journal subjects",
                [](const Json& item) {
                    const auto& subject = exact_object(
                        item, {"kind", "id"}, {"kind", "id"}, "journal subject");
                    return JournalSubject{
                        bounded_string(
                            field(subject, "kind", "journal subject"),
                            "journal subject kind", 1, 128),
                        bounded_string(
                            field(subject, "id", "journal subject"),
                            "journal subject id", 1, 512),
                    };
                }),
            enum_value<JournalSensitivity>(
                field(object, "sensitivity", "session journal record"),
                {
                    {"public", JournalSensitivity::public_},
                    {"metadata", JournalSensitivity::metadata},
                    {"sensitive", JournalSensitivity::sensitive},
                    {"secret", JournalSensitivity::secret},
                },
                "journal sensitivity"),
            field(object, "payload", "session journal record"),
            nullable_decimal("resource_revision"),
            nullable_decimal("previous_resource_revision"),
        };
    });
}

Result<TerminalAttachmentItem> decode_terminal_attachment(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    return guarded<TerminalAttachmentItem>([&] {
        if (envelope_cursor) {
            fail("terminal attachment item must not carry a cursor");
        }
        auto raw = value.as_object();
        if (!raw) {
            fail("terminal attachment item must be an object");
        }
        const auto kind = bounded_string(
            field(*raw.value(), "kind", "terminal attachment"),
            "terminal attachment kind",
            1,
            std::numeric_limits<std::size_t>::max());
        if (kind == "snapshot" || kind == "patch" || kind == "scroll") {
            const auto& object = exact_object(
                value,
                {
                    "kind",
                    "terminal_id",
                    kind == "scroll" ? "scroll" : "render",
                },
                {
                    "kind",
                    "terminal_id",
                    kind == "scroll" ? "scroll" : "render",
                },
                "terminal attachment item");
            auto id = id_value<TerminalId>(
                field(object, "terminal_id", "terminal attachment"),
                "terminal attachment terminal_id");
            if (kind == "snapshot") {
                return TerminalAttachmentItem(TerminalAttachSnapshot{
                    std::move(id),
                    parse_render_snapshot(
                        field(object, "render", "terminal snapshot")),
                });
            }
            if (kind == "patch") {
                return TerminalAttachmentItem(TerminalAttachPatch{
                    std::move(id),
                    parse_render_patch(
                        field(object, "render", "terminal patch")),
                });
            }
            return TerminalAttachmentItem(TerminalAttachScroll{
                std::move(id),
                parse_render_scroll(
                    field(object, "scroll", "terminal scroll")),
            });
        }
        return TerminalAttachmentItem(Unknown{kind, value});
    });
}

Result<BrowserAttachmentItem> decode_browser_attachment(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    return guarded<BrowserAttachmentItem>([&] {
        if (envelope_cursor) {
            fail("browser attachment item must not carry a cursor");
        }
        auto raw = value.as_object();
        if (!raw) {
            fail("browser attachment item must be an object");
        }
        const auto kind = bounded_string(
            field(*raw.value(), "kind", "browser attachment"),
            "browser attachment kind",
            1,
            std::numeric_limits<std::size_t>::max());
        if (kind == "snapshot") {
            const auto& object = exact_object(
                value,
                {"kind", "browser", "size"},
                {"kind", "browser", "size"},
                "browser attachment snapshot");
            return BrowserAttachmentItem(BrowserAttachSnapshot{
                parse_browser(field(object, "browser", "browser snapshot")),
                parse_pixel_size(field(object, "size", "browser snapshot")),
            });
        }
        if (kind == "frame") {
            const auto& object = exact_object(
                value,
                {
                    "kind",
                    "mime_type",
                    "data_base64",
                    "width_px",
                    "height_px",
                    "pointer_frame_seq",
                },
                {
                    "kind",
                    "mime_type",
                    "data_base64",
                    "width_px",
                    "height_px",
                    "pointer_frame_seq",
                },
                "browser attachment frame");
            const auto mime = string_value(
                field(object, "mime_type", "browser frame"),
                "browser frame mime_type");
            if (mime != "image/png" && mime != "image/jpeg") {
                fail("browser frame mime_type is invalid");
            }
            auto data = base64_decode(string_value(
                field(object, "data_base64", "browser frame"),
                "browser frame data_base64"));
            if (!data) {
                fail("browser frame data_base64 is invalid");
            }
            std::optional<std::uint64_t> pointer_frame_seq;
            const auto& raw_pointer_frame_seq =
                field(object, "pointer_frame_seq", "browser frame");
            if (!raw_pointer_frame_seq.is_null()) {
                pointer_frame_seq = decimal_value(
                    raw_pointer_frame_seq,
                    "browser frame pointer_frame_seq");
            }
            return BrowserAttachmentItem(BrowserAttachFrame{
                mime,
                std::move(data).value(),
                static_cast<std::uint32_t>(uint_value(
                    field(object, "width_px", "browser frame"),
                    std::numeric_limits<std::uint32_t>::max(),
                    "browser frame width",
                    true)),
                static_cast<std::uint32_t>(uint_value(
                    field(object, "height_px", "browser frame"),
                    std::numeric_limits<std::uint32_t>::max(),
                    "browser frame height",
                    true)),
                pointer_frame_seq,
            });
        }
        if (kind == "state") {
            const auto& object = exact_object(
                value,
                {"kind", "url", "title", "loading"},
                {"kind", "url", "title", "loading"},
                "browser attachment state");
            return BrowserAttachmentItem(BrowserAttachState{
                string_value(
                    field(object, "url", "browser state"),
                    "browser state url"),
                string_value(
                    field(object, "title", "browser state"),
                    "browser state title"),
                bool_value(
                    field(object, "loading", "browser state"),
                    "browser state loading"),
            });
        }
        return BrowserAttachmentItem(Unknown{kind, value});
    });
}

Result<SidebarViewItem> decode_sidebar_view_item(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    return guarded<SidebarViewItem>([&] {
        if (envelope_cursor) {
            fail("sidebar attachment item must not carry a cursor");
        }
        auto raw = value.as_object();
        if (!raw) {
            fail("sidebar attachment item must be an object");
        }
        const auto kind = bounded_string(
            field(*raw.value(), "kind", "sidebar attachment"),
            "sidebar attachment kind",
            1,
            std::numeric_limits<std::size_t>::max());
        if (kind == "snapshot") {
            const auto& object = exact_object(
                value,
                {"kind", "sidebar_view", "render"},
                {"kind", "sidebar_view", "render"},
                "sidebar attachment snapshot");
            return SidebarViewItem(SidebarAttachSnapshot{
                parse_sidebar(
                    field(object, "sidebar_view", "sidebar snapshot")),
                parse_render_snapshot(
                    field(object, "render", "sidebar snapshot")),
            });
        }
        if (kind == "patch" || kind == "scroll") {
            const auto& object = exact_object(
                value,
                {
                    "kind",
                    "sidebar_view_id",
                    kind == "patch" ? "render" : "scroll",
                },
                {
                    "kind",
                    "sidebar_view_id",
                    kind == "patch" ? "render" : "scroll",
                },
                "sidebar attachment item");
            auto id = id_value<SidebarViewId>(
                field(object, "sidebar_view_id", "sidebar attachment"),
                "sidebar attachment id");
            if (kind == "patch") {
                return SidebarViewItem(SidebarAttachPatch{
                    std::move(id),
                    parse_render_patch(
                        field(object, "render", "sidebar patch")),
                });
            }
            return SidebarViewItem(SidebarAttachScroll{
                std::move(id),
                parse_render_scroll(
                    field(object, "scroll", "sidebar scroll")),
            });
        }
        return SidebarViewItem(Unknown{kind, value});
    });
}

Result<ViewerResizeResult> decode_viewer_resize(const Json& value) {
    return decode_value<ViewerResizeResult>(value);
}

Result<BrowserViewerResizeResult> decode_browser_viewer_resize(
    const Json& value) {
    return decode_value<BrowserViewerResizeResult>(value);
}

Result<ViewerReleaseResult> decode_viewer_release(const Json& value) {
    return decode_value<ViewerReleaseResult>(value);
}

Result<EmptyResult> decode_empty_result(const Json& value) {
    return decode_value<EmptyResult>(value);
}

}  // namespace detail

Result<ConfirmationRequiredDetails> decode_confirmation_required_details(
    const Error& error) {
    if (error.protocol_code != "confirmation.required") {
        return make_error(
            ErrorCode::invalid_argument,
            "error code is not confirmation.required");
    }
    if (!error.details) {
        return make_error(
            ErrorCode::decode,
            "confirmation.required error is missing details");
    }
    return detail::decode_value<ConfirmationRequiredDetails>(*error.details);
}

}  // namespace cmux
