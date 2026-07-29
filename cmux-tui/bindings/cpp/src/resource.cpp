#include "cmux/resource.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <deque>
#include <limits>
#include <mutex>
#include <random>
#include <sstream>
#include <stdexcept>
#include <utility>

#if defined(__APPLE__)
#include <stdlib.h>
#elif defined(__linux__)
#include <sys/random.h>
#endif

namespace cmux {
namespace {

struct OperationInfo {
    std::string_view name;
    OperationClass operation_class;
};

#define CMUX_OPERATION_TABLE(X)                                                       \
    X(machine_list, "machine.list", read)                                             \
    X(machine_get, "machine.get", read)                                               \
    X(machine_create, "machine.create", mutation)                                     \
    X(machine_rename, "machine.rename", mutation)                                     \
    X(machine_delete, "machine.delete", mutation)                                     \
    X(machine_restore, "machine.restore", mutation)                                   \
    X(machine_purge, "machine.purge", mutation)                                       \
    X(machine_connect_external, "machine.connect_external", mutation)                 \
    X(session_list, "session.list", read)                                             \
    X(session_open, "session.open", mutation)                                         \
    X(session_get, "session.get", read)                                               \
    X(session_snapshot, "session.snapshot", read)                                     \
    X(session_events, "session.events", stream_open)                                  \
    X(session_ping, "session.ping", read)                                             \
    X(session_shutdown, "session.shutdown", mutation)                                 \
    X(session_reload_config, "session.reload_config", mutation)                       \
    X(session_terminal_defaults_update, "session.terminal_defaults.update", mutation) \
    X(client_list, "client.list", read)                                               \
    X(client_get, "client.get", read)                                                 \
    X(client_metadata_update, "client.metadata.update", connection_control)           \
    X(client_sizing_set, "client.sizing.set", connection_control)                     \
    X(client_sizing_release, "client.sizing.release", connection_control)             \
    X(client_cell_pixels_set, "client.cell_pixels.set", connection_control)           \
    X(client_detach, "client.detach", connection_control)                             \
    X(session_window_title_set, "session.window.title.set", mutation)                 \
    X(session_window_title_clear, "session.window.title.clear", mutation)             \
    X(pairing_request_list, "pairing_request.list", read)                             \
    X(pairing_request_resolve, "pairing_request.resolve", mutation)                   \
    X(frontend_projection_get, "frontend_projection.get", read)                       \
    X(frontend_projection_put, "frontend_projection.put", mutation)                   \
    X(workspace_list, "workspace.list", read)                                         \
    X(workspace_get, "workspace.get", read)                                           \
    X(workspace_create, "workspace.create", mutation)                                 \
    X(workspace_rename, "workspace.rename", mutation)                                 \
    X(workspace_move, "workspace.move", mutation)                                     \
    X(workspace_focus, "workspace.focus", mutation)                                   \
    X(workspace_close, "workspace.close", mutation)                                   \
    X(workspace_run, "workspace.run", mutation)                                       \
    X(workspace_layout_apply, "workspace.layout.apply", mutation)                     \
    X(screen_list, "screen.list", read)                                               \
    X(screen_get, "screen.get", read)                                                 \
    X(screen_create, "screen.create", mutation)                                       \
    X(screen_rename, "screen.rename", mutation)                                       \
    X(screen_focus, "screen.focus", mutation)                                         \
    X(screen_close, "screen.close", mutation)                                         \
    X(screen_layout_export, "screen.layout.export", read)                             \
    X(screen_layout_undo, "screen.layout.undo", mutation)                             \
    X(pane_list, "pane.list", read)                                                   \
    X(pane_get, "pane.get", read)                                                     \
    X(pane_create, "pane.create", mutation)                                           \
    X(pane_split, "pane.split", mutation)                                             \
    X(pane_rename, "pane.rename", mutation)                                           \
    X(pane_focus, "pane.focus", mutation)                                             \
    X(pane_focus_direction, "pane.focus_direction", mutation)                         \
    X(pane_neighbor_get, "pane.neighbor.get", read)                                   \
    X(pane_swap, "pane.swap", mutation)                                               \
    X(pane_zoom, "pane.zoom", mutation)                                               \
    X(pane_split_ratio_set, "pane.split_ratio.set", mutation)                         \
    X(pane_viewport_width_set, "pane.viewport_width.set", mutation)                   \
    X(pane_close, "pane.close", mutation)                                             \
    X(pane_run, "pane.run", mutation)                                                 \
    X(tab_list, "tab.list", read)                                                     \
    X(tab_get, "tab.get", read)                                                       \
    X(tab_create_terminal, "tab.create_terminal", mutation)                           \
    X(tab_create_browser, "tab.create_browser", mutation)                             \
    X(tab_rename, "tab.rename", mutation)                                             \
    X(tab_move, "tab.move", mutation)                                                 \
    X(tab_focus, "tab.focus", mutation)                                               \
    X(tab_close, "tab.close", mutation)                                               \
    X(terminal_list, "terminal.list", read)                                           \
    X(terminal_get, "terminal.get", read)                                             \
    X(terminal_input_write, "terminal.input.write", mutation)                         \
    X(terminal_input_keys, "terminal.input.keys", mutation)                           \
    X(terminal_input_mouse, "terminal.input.mouse", mutation)                         \
    X(terminal_input_focus, "terminal.input.focus", mutation)                         \
    X(terminal_screen_read, "terminal.screen.read", read)                             \
    X(terminal_state_read, "terminal.state.read", read)                               \
    X(terminal_history_read, "terminal.history.read", read)                           \
    X(terminal_history_clear, "terminal.history.clear", mutation)                     \
    X(terminal_wait, "terminal.wait", read)                                           \
    X(terminal_copy, "terminal.copy", read)                                           \
    X(terminal_process_get, "terminal.process.get", read)                             \
    X(terminal_renderer_grant_create, "terminal.renderer_grant.create",               \
      connection_control)                                                             \
    X(terminal_viewer_resize, "terminal.viewer.resize", connection_control)           \
    X(terminal_viewer_release, "terminal.viewer.release", connection_control)         \
    X(terminal_viewport_scroll, "terminal.viewport.scroll", mutation)                 \
    X(terminal_move, "terminal.move", mutation)                                       \
    X(terminal_attach, "terminal.attach", stream_open)                                \
    X(terminal_close, "terminal.close", mutation)                                     \
    X(browser_list, "browser.list", read)                                             \
    X(browser_get, "browser.get", read)                                               \
    X(browser_navigate, "browser.navigate", mutation)                                 \
    X(browser_back, "browser.back", mutation)                                         \
    X(browser_forward, "browser.forward", mutation)                                   \
    X(browser_reload, "browser.reload", mutation)                                     \
    X(browser_activate, "browser.activate", mutation)                                 \
    X(browser_input_key, "browser.input.key", mutation)                               \
    X(browser_input_text, "browser.input.text", mutation)                             \
    X(browser_input_mouse, "browser.input.mouse", mutation)                           \
    X(browser_input_wheel, "browser.input.wheel", mutation)                           \
    X(browser_viewer_resize, "browser.viewer.resize", connection_control)             \
    X(browser_viewer_release, "browser.viewer.release", connection_control)           \
    X(browser_attach, "browser.attach", stream_open)                                  \
    X(browser_close, "browser.close", mutation)                                       \
    X(notification_list, "notification.list", read)                                   \
    X(notification_create, "notification.create", mutation)                           \
    X(agent_list, "agent.list", read)                                                 \
    X(agent_report, "agent.report", mutation)                                         \
    X(sidebar_view_get, "sidebar_view.get", read)                                     \
    X(sidebar_view_ensure, "sidebar_view.ensure", mutation)                           \
    X(sidebar_view_attach, "sidebar_view.attach", stream_open)                        \
    X(sidebar_view_input, "sidebar_view.input", mutation)                             \
    X(sidebar_view_resize, "sidebar_view.resize", mutation)                           \
    X(sidebar_view_reload, "sidebar_view.reload", mutation)                           \
    X(provider_scope_list, "provider_scope.list", read)                               \
    X(provider_action_invoke, "provider_action.invoke", mutation)                     \
    X(provider_notice_acknowledge, "provider_notice.acknowledge",                     \
      connection_control)                                                             \
    X(provider_notice_events, "provider_notice.events", stream_open)                  \
    X(provider_workspace_mark, "provider_workspace.mark", mutation)                   \
    X(provider_workspace_rename, "provider_workspace.rename", mutation)               \
    X(provider_workspace_close, "provider_workspace.close", mutation)                 \
    X(stream_cancel, "stream.cancel", connection_control)

[[nodiscard]] OperationInfo info_for(Operation operation) noexcept {
    switch (operation) {
#define CMUX_OPERATION_CASE(symbol, wire, classification) \
    case Operation::symbol:                                \
        return {wire, OperationClass::classification};
        CMUX_OPERATION_TABLE(CMUX_OPERATION_CASE)
#undef CMUX_OPERATION_CASE
    }
    return {"", OperationClass::read};
}

[[nodiscard]] bool requires_machine(Operation operation) noexcept {
    switch (operation) {
        case Operation::machine_list:
        case Operation::machine_create:
        case Operation::machine_connect_external:
            return false;
        default:
            return true;
    }
}

[[nodiscard]] bool requires_session(Operation operation) noexcept {
    switch (operation) {
        case Operation::machine_list:
        case Operation::machine_get:
        case Operation::machine_create:
        case Operation::machine_rename:
        case Operation::machine_delete:
        case Operation::machine_restore:
        case Operation::machine_purge:
        case Operation::machine_connect_external:
        case Operation::session_list:
        case Operation::provider_scope_list:
        case Operation::provider_action_invoke:
        case Operation::provider_notice_acknowledge:
        case Operation::provider_notice_events:
            return false;
        default:
            return true;
    }
}

[[nodiscard]] bool supports_expected_revision(Operation operation) noexcept {
    if (info_for(operation).operation_class != OperationClass::mutation) {
        return false;
    }
    switch (operation) {
        case Operation::machine_create:
        case Operation::machine_connect_external:
        case Operation::workspace_create:
            return false;
        default:
            return true;
    }
}

void inject_routing(
    const ClientOptions& options,
    Operation operation,
    Json::Object& params) {
    if (requires_machine(operation) && !params.contains("machine")) {
        params.emplace("machine", Json(options.machine_selector));
    }
    if (requires_session(operation) && !params.contains("session")) {
        params.emplace("session", Json(options.session_selector));
    }
}

[[nodiscard]] Error wrong_class(
    Operation operation,
    OperationClass expected) {
    std::string expected_name;
    switch (expected) {
        case OperationClass::read:
            expected_name = "read";
            break;
        case OperationClass::mutation:
            expected_name = "mutation";
            break;
        case OperationClass::stream_open:
            expected_name = "stream_open";
            break;
        case OperationClass::connection_control:
            expected_name = "connection_control";
            break;
    }
    return make_error(
        ErrorCode::invalid_argument,
        "'" + std::string(operation_name(operation)) + "' is not a " +
            expected_name + " operation");
}

[[nodiscard]] Result<std::uint64_t> decimal_u64(
    const Json& value,
    std::string_view context) {
    if (auto number = value.as_uint64()) {
        return number.value();
    }
    if (auto text = value.as_string()) {
        if (text.value().empty()) {
            return make_error(
                ErrorCode::decode,
                std::string(context) + " must be a decimal string");
        }
        std::uint64_t parsed = 0;
        for (const char byte : text.value()) {
            if (byte < '0' || byte > '9') {
                return make_error(
                    ErrorCode::decode,
                    std::string(context) + " must be a decimal string");
            }
            const auto digit = static_cast<std::uint64_t>(byte - '0');
            if (parsed >
                (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) {
                return make_error(
                    ErrorCode::decode,
                    std::string(context) + " exceeds uint64");
            }
            parsed = parsed * 10U + digit;
        }
        return parsed;
    }
    return make_error(
        ErrorCode::decode,
        std::string(context) + " must be a decimal string");
}

[[nodiscard]] Result<Cursor> parse_cursor(const Json& value) {
    auto object = value.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "cursor must be an object");
    }
    auto generation = require_string(value, "generation");
    if (!generation) {
        return std::move(generation).error();
    }
    const Json* revision = value.find("revision");
    if (!revision) {
        return make_error(ErrorCode::decode, "cursor is missing revision");
    }
    auto parsed_revision = decimal_u64(*revision, "cursor revision");
    if (!parsed_revision) {
        return std::move(parsed_revision).error();
    }
    return Cursor{std::move(generation).value(), parsed_revision.value()};
}

template <typename Id>
[[nodiscard]] Result<std::optional<Id>> optional_id(
    const Json& object,
    std::string_view field) {
    const Json* value = object.find(field);
    if (!value || value->is_null()) {
        return std::optional<Id>{};
    }
    auto text = value->as_string();
    if (!text) {
        return make_error(
            ErrorCode::decode,
            std::string(field) + " ID must be a string");
    }
    auto parsed = Id::parse(text.value());
    if (!parsed) {
        return std::move(parsed).error();
    }
    return std::optional<Id>(std::move(parsed).value());
}

template <typename Id>
[[nodiscard]] Result<Id> required_id(
    const Json& object,
    std::string_view field) {
    const Json* value = object.find(field);
    if (!value) {
        return make_error(
            ErrorCode::decode,
            std::string("created path is missing ") + std::string(field));
    }
    auto text = value->as_string();
    if (!text) {
        return make_error(
            ErrorCode::decode,
            std::string(field) + " ID must be a string");
    }
    auto parsed = Id::parse(text.value());
    if (!parsed) {
        return std::move(parsed).error();
    }
    return std::move(parsed).value();
}

[[nodiscard]] Result<CreatedPath> parse_created_path(const Json& value) {
    auto object = value.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "created path must be an object");
    }
    auto kind = require_string(value, "kind");
    if (!kind) {
        return std::move(kind).error();
    }
    auto workspace = required_id<WorkspaceId>(value, "workspace_id");
    if (!workspace) {
        return std::move(workspace).error();
    }
    if (kind.value() == "workspace") {
        return CreatedPath(CreatedWorkspaceOnly{
            std::move(workspace).value(),
        });
    }
    auto screen = required_id<ScreenId>(value, "screen_id");
    if (!screen) {
        return std::move(screen).error();
    }
    auto pane = required_id<PaneId>(value, "pane_id");
    if (!pane) {
        return std::move(pane).error();
    }
    auto tab = required_id<TabId>(value, "tab_id");
    if (!tab) {
        return std::move(tab).error();
    }
    if (kind.value() == "terminal") {
        auto terminal = required_id<TerminalId>(value, "terminal_id");
        if (!terminal) {
            return std::move(terminal).error();
        }
        return CreatedPath(CreatedTerminalPath{
            std::move(workspace).value(),
            std::move(screen).value(),
            std::move(pane).value(),
            std::move(tab).value(),
            std::move(terminal).value(),
        });
    }
    if (kind.value() == "browser") {
        auto browser = required_id<BrowserId>(value, "browser_id");
        if (!browser) {
            return std::move(browser).error();
        }
        return CreatedPath(CreatedBrowserPath{
            std::move(workspace).value(),
            std::move(screen).value(),
            std::move(pane).value(),
            std::move(tab).value(),
            std::move(browser).value(),
        });
    }
    return make_error(ErrorCode::decode, "unknown created path kind");
}

[[nodiscard]] Result<MutationResult> decode_mutation(Json result) {
    auto object = result.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "mutation result must be an object");
    }
    MutationResult decoded;
    auto generation = require_string(result, "generation");
    if (!generation || generation.value().empty() ||
        generation.value().size() > 128U) {
        return make_error(
            ErrorCode::decode,
            "mutation result generation must contain 1 to 128 bytes");
    }
    const Json* revision = result.find("revision");
    if (!revision) {
        return make_error(
            ErrorCode::decode,
            "mutation result is missing revision");
    }
    auto parsed_revision = decimal_u64(*revision, "mutation revision");
    if (!parsed_revision) {
        return std::move(parsed_revision).error();
    }
    auto replayed = require_bool(result, "replayed");
    if (!replayed) {
        return std::move(replayed).error();
    }
    const Json* value = result.find("value");
    if (!value) {
        return make_error(
            ErrorCode::decode,
            "mutation result is missing value");
    }
    decoded.value = *value;
    decoded.generation = std::move(generation).value();
    decoded.revision = parsed_revision.value();
    decoded.replayed = replayed.value();
    return decoded;
}

[[nodiscard]] bool secret_field(std::string_view key) {
    return key == "token" || key == "specifier" || key == "credential" || key == "secret" ||
           key == "provider_credential" || key == "authority_secret";
}

[[nodiscard]] Json redact_json(const Json& value) {
    if (auto object = value.as_object()) {
        Json::Object redacted;
        for (const auto& [key, item] : *object.value()) {
            redacted.emplace(
                key,
                secret_field(key) ? Json("[REDACTED]") : redact_json(item));
        }
        return Json(std::move(redacted));
    }
    if (auto array = value.as_array()) {
        Json::Array redacted;
        redacted.reserve(array.value()->size());
        for (const auto& item : *array.value()) {
            redacted.emplace_back(redact_json(item));
        }
        return Json(std::move(redacted));
    }
    return value;
}

[[nodiscard]] Error protocol_error(const Json& response) {
    Error decoded = make_error(ErrorCode::command, "cmux operation failed");
    decoded.response = std::make_shared<Json>(redact_json(response));
    const Json* value = response.find("error");
    if (!value || !value->is_object()) {
        return decoded;
    }
    if (const Json* code = value->find("code")) {
        if (auto text = code->as_string()) {
            decoded.protocol_code = std::string(text.value());
        }
    }
    if (const Json* message = value->find("message")) {
        if (auto text = message->as_string()) {
            decoded.message = std::string(text.value());
        }
    }
    if (const Json* details = value->find("details")) {
        decoded.details = std::make_shared<Json>(redact_json(*details));
    }
    if (const Json* retryable = value->find("retryable")) {
        if (auto boolean = retryable->as_bool()) {
            decoded.retryable = boolean.value();
        }
    }
    return decoded;
}

[[nodiscard]] Result<Json> decode_response(
    const Json& response,
    std::string_view request_id) {
    auto object = response.as_object();
    if (!object) {
        return make_error(ErrorCode::protocol, "response must be an object");
    }
    auto protocol = require_string(response, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/1") {
        return make_error(
            ErrorCode::protocol,
            "response protocol must be cmux.protocol/1");
    }
    auto type = require_string(response, "type");
    if (!type || type.value() != "response") {
        return make_error(ErrorCode::protocol, "expected response envelope");
    }
    auto id = require_string(response, "id");
    if (!id || id.value() != request_id) {
        return make_error(ErrorCode::protocol, "response request ID mismatch");
    }
    const Json* ok = response.find("ok");
    if (!ok) {
        return make_error(ErrorCode::protocol, "response is missing ok");
    }
    auto succeeded = ok->as_bool();
    if (!succeeded) {
        return make_error(ErrorCode::protocol, "response ok must be boolean");
    }
    if (!succeeded.value()) {
        return protocol_error(response);
    }
    if (const Json* result = response.find("result")) {
        return *result;
    }
    return Json(Json::Object{});
}

[[nodiscard]] std::array<unsigned char, 16> secure_random_128() {
    std::array<unsigned char, 16> bytes{};
#if defined(__APPLE__)
    ::arc4random_buf(bytes.data(), bytes.size());
#elif defined(__linux__)
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        const auto count =
            ::getrandom(bytes.data() + offset, bytes.size() - offset, 0);
        if (count > 0) {
            offset += static_cast<std::size_t>(count);
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        throw std::runtime_error("OS randomness unavailable");
    }
#else
    std::random_device random;
    if (random.entropy() <= 0.0) {
        throw std::runtime_error("OS-backed std::random_device unavailable");
    }
    for (std::size_t offset = 0; offset < bytes.size(); offset += 4) {
        const auto word = random();
        for (std::size_t byte = 0; byte < 4 && offset + byte < bytes.size(); ++byte) {
            bytes[offset + byte] =
                static_cast<unsigned char>((word >> (byte * 8U)) & 0xffU);
        }
    }
#endif
    return bytes;
}

[[nodiscard]] std::string hex_128(
    std::string_view prefix,
    const std::array<unsigned char, 16>& bytes) {
    constexpr char hex[] = "0123456789abcdef";
    std::string result(prefix);
    result.reserve(prefix.size() + 32);
    for (const auto byte : bytes) {
        result.push_back(hex[(byte >> 4U) & 0x0fU]);
        result.push_back(hex[byte & 0x0fU]);
    }
    return result;
}

[[nodiscard]] std::string make_stream_value() {
    return hex_128("stream_", secure_random_128());
}

[[nodiscard]] Json cursor_json(const Cursor& cursor) {
    return Json(Json::Object{
        {"generation", Json(cursor.generation)},
        {"revision", Json(std::to_string(cursor.revision))},
    });
}

template <typename Id>
[[nodiscard]] Result<ResourceSnapshot<Id>> decode_snapshot(
    Json value,
    const Id& fallback_id) {
    auto object = value.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "resource snapshot must be an object");
    }
    ResourceSnapshot<Id> snapshot;
    snapshot.id = fallback_id;
    if (const Json* id = value.find("id")) {
        auto text = id->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "resource ID must be a string");
        }
        auto parsed = Id::parse(text.value());
        if (!parsed) {
            return std::move(parsed).error();
        }
        snapshot.id = std::move(parsed).value();
    }
    if (const Json* name = value.find("name"); name && !name->is_null()) {
        auto text = name->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "resource name must be a string");
        }
        snapshot.name = std::string(text.value());
    }
    if (const Json* label = value.find("label"); label && !label->is_null()) {
        auto text = label->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "resource label must be a string");
        }
        snapshot.label = std::string(text.value());
    }
    if (const Json* revision = value.find("revision")) {
        auto parsed = decimal_u64(*revision, "resource revision");
        if (!parsed) {
            return std::move(parsed).error();
        }
        snapshot.revision = parsed.value();
    }
    const Json* parents = value.find("parents");
    const Json& parent_source =
        parents && parents->is_object() ? *parents : value;
#define CMUX_PARSE_PARENT(field)                                            \
    do {                                                                    \
        auto parsed = optional_id<typename decltype(snapshot.parents.field)::value_type>( \
            parent_source, #field);                                         \
        if (!parsed) return std::move(parsed).error();                       \
        snapshot.parents.field = std::move(parsed).value();                  \
    } while (false)
    CMUX_PARSE_PARENT(machine);
    CMUX_PARSE_PARENT(session);
    CMUX_PARSE_PARENT(workspace);
    CMUX_PARSE_PARENT(screen);
    CMUX_PARSE_PARENT(pane);
    CMUX_PARSE_PARENT(tab);
#undef CMUX_PARSE_PARENT
    snapshot.raw = std::move(value);
    return snapshot;
}

}  // namespace

std::string_view operation_name(Operation operation) noexcept {
    return info_for(operation).name;
}

OperationClass operation_class(Operation operation) noexcept {
    return info_for(operation).operation_class;
}

Result<std::optional<CreatedPath>> MutationResult::created_path() const {
    const Json* kind = value.find("kind");
    if (!kind) {
        return std::optional<CreatedPath>{};
    }
    auto text = kind->as_string();
    if (!text ||
        (text.value() != "workspace" &&
         text.value() != "terminal" &&
         text.value() != "browser")) {
        return std::optional<CreatedPath>{};
    }
    auto parsed = parse_created_path(value);
    if (!parsed) {
        return std::move(parsed).error();
    }
    return std::optional<CreatedPath>(std::move(parsed).value());
}

Result<MutationOptions> MutationOptions::with_key(std::string key) {
    if (key.empty() || key.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "idempotency key must contain 1 to 128 UTF-8 bytes");
    }
    return MutationOptions(std::move(key));
}

MutationOptions MutationOptions::unique() {
    return MutationOptions(hex_128("cpp_", secure_random_128()));
}

Result<RunCommand> RunCommand::exact(std::vector<std::string> argv) {
    if (argv.empty() ||
        std::ranges::any_of(argv, [](const auto& argument) {
            return argument.empty();
        })) {
        return make_error(
            ErrorCode::invalid_argument,
            "argv must contain only non-empty strings");
    }
    return RunCommand(std::move(argv));
}

Result<RunCommand> RunCommand::shell(std::string script) {
    if (script.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "shell script must not be empty");
    }
    return RunCommand(std::move(script));
}

Result<RunCommand> RunCommand::shell_with_executable(
    std::string executable,
    std::string script) {
    return exact(
        {std::move(executable), std::string("-lc"), std::move(script)});
}

void RunCommand::encode_into(Json::Object& params) const {
    if (shell_script_) {
        params.insert_or_assign("shell", Json(*shell_script_));
        return;
    }
    Json::Array argv;
    argv.reserve(argv_.size());
    for (const auto& value : argv_) {
        argv.emplace_back(value);
    }
    params.insert_or_assign("argv", Json(std::move(argv)));
}

Result<Json::Object> RunOptions::to_params() const {
    Json::Object params;
    command.encode_into(params);
    if (cwd) {
        params.emplace("cwd", Json(*cwd));
    }
    if (name) {
        params.emplace("name", Json(*name));
    }
    if (columns.has_value() != rows.has_value()) {
        return make_error(
            ErrorCode::invalid_argument,
            "columns and rows must be supplied together");
    }
    if (columns) {
        if (*columns == 0 || *rows == 0) {
            return make_error(
                ErrorCode::invalid_argument,
                "columns and rows must be positive");
        }
        params.emplace("cols", Json(static_cast<std::uint64_t>(*columns)));
        params.emplace("rows", Json(static_cast<std::uint64_t>(*rows)));
    }
    return params;
}

Result<Json::Object> CreateTerminalTabOptions::to_params() const {
    Json::Object params;
    if (cwd) {
        params.emplace("cwd", Json(*cwd));
    }
    if (name) {
        params.emplace("name", Json(*name));
    }
    if (columns.has_value() != rows.has_value()) {
        return make_error(
            ErrorCode::invalid_argument,
            "columns and rows must be supplied together");
    }
    if (columns) {
        if (*columns == 0 || *rows == 0) {
            return make_error(
                ErrorCode::invalid_argument,
                "columns and rows must be positive");
        }
        params.emplace("cols", Json(static_cast<std::uint64_t>(*columns)));
        params.emplace("rows", Json(static_cast<std::uint64_t>(*rows)));
    }
    return params;
}

Result<Json::Object> CreateBrowserTabOptions::to_params() const {
    if (url.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "browser URL must not be empty");
    }
    Json::Object params{{"url", Json(url)}};
    if (name) {
        params.emplace("name", Json(*name));
    }
    if (width_px.has_value() != height_px.has_value()) {
        return make_error(
            ErrorCode::invalid_argument,
            "width_px and height_px must be supplied together");
    }
    if (width_px) {
        if (*width_px == 0 || *height_px == 0) {
            return make_error(
                ErrorCode::invalid_argument,
                "browser pixel dimensions must be positive");
        }
        params.emplace("width_px", Json(static_cast<std::uint64_t>(*width_px)));
        params.emplace(
            "height_px", Json(static_cast<std::uint64_t>(*height_px)));
    }
    return params;
}

namespace detail {

class ResourceClientState
    : public std::enable_shared_from_this<ResourceClientState> {
public:
    ClientOptions options;
    std::unique_ptr<Transport> control;
    TransportFactory stream_factory;
    std::mutex request_mutex;
    std::atomic<std::uint64_t> next_request_id{1};
    std::atomic<bool> is_closed{false};

    [[nodiscard]] Result<Json> call(
        Operation operation,
        Json::Object params,
        std::optional<std::string> idempotency_key) {
        std::lock_guard lock(request_mutex);
        if (is_closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "client is closed");
        }
        const auto request_id =
            "cpp-request-" +
            std::to_string(
                next_request_id.fetch_add(1, std::memory_order_relaxed));
        inject_routing(options, operation, params);
        auto sent = send_envelope(
            *control,
            request_id,
            operation,
            std::move(params),
            std::move(idempotency_key));
        if (!sent) {
            return std::move(sent).error();
        }
        while (true) {
            auto wire = control->receive(options.timeout);
            if (!wire) {
                return std::move(wire).error();
            }
            auto parsed = Json::parse(wire.value(), options.json_limits);
            if (!parsed) {
                return std::move(parsed).error();
            }
            const Json* type = parsed.value().find("type");
            if (!type) {
                return make_error(
                    ErrorCode::protocol,
                    "server envelope is missing type");
            }
            auto type_name = type->as_string();
            if (!type_name) {
                return make_error(
                    ErrorCode::protocol,
                    "server envelope type must be a string");
            }
            if (type_name.value() != "response") {
                continue;
            }
            const Json* id = parsed.value().find("id");
            if (!id) {
                continue;
            }
            auto response_id = id->as_string();
            if (!response_id || response_id.value() != request_id) {
                continue;
            }
            return decode_response(parsed.value(), request_id);
        }
    }

    [[nodiscard]] Result<std::unique_ptr<ResourceStream::Impl>> open_stream(
        Operation operation,
        Json::Object params);

    void close() noexcept {
        bool expected = false;
        if (is_closed.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel)) {
            control->close();
        }
    }

    [[nodiscard]] static Result<void> send_envelope(
        Transport& transport,
        std::string_view request_id,
        Operation operation,
        Json::Object params,
        std::optional<std::string> idempotency_key,
        Timeout timeout = std::chrono::seconds(10),
        JsonLimits limits = {}) {
        Json::Object envelope{
            {"protocol", Json("cmux.protocol/1")},
            {"type", Json("request")},
            {"id", Json(std::string(request_id))},
            {"operation", Json(std::string(operation_name(operation)))},
            {"params", Json(std::move(params))},
        };
        if (idempotency_key) {
            envelope.emplace(
                "idempotency_key", Json(std::move(*idempotency_key)));
        }
        auto encoded = Json(std::move(envelope)).encode(limits);
        if (!encoded) {
            return std::move(encoded).error();
        }
        if (encoded.value().size() > 4U * 1024U * 1024U) {
            return make_error(
                ErrorCode::invalid_argument,
                "resource request exceeds 4 MiB");
        }
        return transport.send(encoded.value(), timeout);
    }
};

Result<Json> resource_read(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::read) {
        return wrong_class(operation, OperationClass::read);
    }
    return state->call(operation, std::move(params), std::nullopt);
}

Result<Json> resource_control(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::connection_control) {
        return wrong_class(operation, OperationClass::connection_control);
    }
    return state->call(operation, std::move(params), std::nullopt);
}

Result<MutationResult> resource_mutate(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    MutationOptions options) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::mutation) {
        return wrong_class(operation, OperationClass::mutation);
    }
    if (const auto revision = options.expected_revision()) {
        if (!supports_expected_revision(operation)) {
            return make_error(
                ErrorCode::invalid_argument,
                "this mutation does not accept expected_revision");
        }
        params.insert_or_assign(
            "expected_revision", Json(std::to_string(*revision)));
    }
    const auto expected_key = options.idempotency_key();
    auto result = state->call(
        operation,
        std::move(params),
        expected_key);
    if (!result) {
        return std::move(result).error();
    }
    auto decoded = decode_mutation(std::move(result).value());
    if (!decoded) {
        return std::move(decoded).error();
    }
    return decoded;
}

}  // namespace detail

Client::Client(std::shared_ptr<detail::ResourceClientState> state)
    : state_(std::move(state)) {}

Client::Client(Client&&) noexcept = default;
Client& Client::operator=(Client&&) noexcept = default;

Client::~Client() {
    close();
}

Result<Client> Client::connect(ClientOptions options) {
    if (options.machine_selector.empty() || options.session_selector.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "machine and session routing selectors must not be empty");
    }
    std::string path = options.socket_path;
    if (path.empty()) {
        path = socket_path_from_environment();
    }
    if (path.empty()) {
        path = default_socket_path(options.session);
    }
    if (!options.transport_factory) {
        options.transport_factory = unix_transport_factory(
            path, options.timeout, options.transport_limits);
    }
    if (!options.stream_transport_factory) {
        options.stream_transport_factory = options.transport_factory;
    }
    auto connected = options.transport_factory();
    if (!connected) {
        return std::move(connected).error();
    }
    auto state = std::make_shared<detail::ResourceClientState>();
    state->control = std::move(connected).value();
    state->stream_factory = options.stream_transport_factory;
    state->options = std::move(options);
    return Client(std::move(state));
}

void Client::close() noexcept {
    if (state_) {
        state_->close();
    }
}

bool Client::closed() const noexcept {
    return !state_ || state_->is_closed.load(std::memory_order_acquire);
}

Result<Json> Client::read(
    Operation operation,
    Json::Object params) const {
    return detail::resource_read(state_, operation, std::move(params));
}

Result<MutationResult> Client::mutate(
    Operation operation,
    Json::Object params,
    MutationOptions options) const {
    return detail::resource_mutate(
        state_, operation, std::move(params), std::move(options));
}

Result<Json> Client::connection_control(
    Operation operation,
    Json::Object params) const {
    return detail::resource_control(state_, operation, std::move(params));
}

Result<ResourceStream> Client::open_stream(
    Operation operation,
    Json::Object params) const {
    return detail::resource_open_stream(state_, operation, std::move(params));
}

Result<SessionEventStream> Client::open_session_events(
    Json::Object params) const {
    auto stream = open_stream(Operation::session_events, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionEventStream(std::move(stream).value());
}

Result<TerminalAttachmentStream> Client::open_terminal_attachment(
    Json::Object params) const {
    auto stream = open_stream(Operation::terminal_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return TerminalAttachmentStream(std::move(stream).value());
}

Result<BrowserAttachmentStream> Client::open_browser_attachment(
    Json::Object params) const {
    auto stream = open_stream(Operation::browser_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return BrowserAttachmentStream(std::move(stream).value());
}

Result<SidebarViewStream> Client::open_sidebar_view(
    Json::Object params) const {
    auto stream = open_stream(Operation::sidebar_view_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return SidebarViewStream(std::move(stream).value());
}

Result<ProviderNoticeStream> Client::open_provider_notices(
    Json::Object params) const {
    auto stream =
        open_stream(Operation::provider_notice_events, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return ProviderNoticeStream(std::move(stream).value());
}

Machine Client::machine(MachineId id) const {
    return Machine(state_, std::move(id), "machine");
}

Session Client::session(SessionId id) const {
    return Session(state_, std::move(id), "session");
}

Workspace Client::workspace(WorkspaceId id) const {
    return Workspace(state_, std::move(id), "workspace");
}

Screen Client::screen(ScreenId id) const {
    return Screen(state_, std::move(id), "screen");
}

Pane Client::pane(PaneId id) const {
    return Pane(state_, std::move(id), "pane");
}

Tab Client::tab(TabId id) const {
    return Tab(state_, std::move(id), "tab");
}

Terminal Client::terminal(TerminalId id) const {
    return Terminal(state_, std::move(id), "terminal");
}

Browser Client::browser(BrowserId id) const {
    return Browser(state_, std::move(id), "browser");
}

ConnectedClient Client::connected_client(ConnectedClientId id) const {
    return ConnectedClient(state_, std::move(id), "client");
}

Notification Client::notification(NotificationId id) const {
    return Notification(state_, std::move(id), "notification");
}

Agent Client::agent(AgentId id) const {
    return Agent(state_, std::move(id), "agent");
}

PairingRequest Client::pairing_request(PairingRequestId id) const {
    return PairingRequest(state_, std::move(id), "pairing_request");
}

FrontendProjection Client::projection(FrontendProjectionId id) const {
    return FrontendProjection(
        state_, std::move(id), "frontend_projection");
}

SidebarView Client::sidebar_view(SidebarViewId id) const {
    return SidebarView(state_, std::move(id), "sidebar_view");
}

ProviderScope Client::provider_scope(ProviderScopeId id) const {
    return ProviderScope(state_, std::move(id), "provider_scope");
}

ProviderAction Client::provider_action(ProviderActionId id) const {
    return ProviderAction(state_, std::move(id), "provider_action");
}

ProviderNoticeHandle Client::provider_notice(ProviderNoticeId id) const {
    return ProviderNoticeHandle(state_, std::move(id), "provider_notice");
}

Result<Json> Client::machines() const {
    return read(Operation::machine_list);
}

Result<Json> Client::sessions(
    std::optional<Selector<MachineId>> machine_selector) const {
    Json::Object params;
    if (machine_selector) {
        params.emplace("machine", Json(machine_selector->wire()));
    }
    return read(Operation::session_list, std::move(params));
}

Result<MutationResult> Client::create_machine(
    ProviderScopeId provider_scope,
    MutationOptions options) const {
    return mutate(
        Operation::machine_create,
        Json::Object{
            {"provider_scope", Json(provider_scope.value())},
        },
        std::move(options));
}

Result<MutationResult> Client::connect_external_machine(
    ProviderScopeId provider_scope,
    const SensitiveString& specifier,
    MutationOptions options) const {
    return mutate(
        Operation::machine_connect_external,
        Json::Object{
            {"provider_scope", Json(provider_scope.value())},
            {"specifier", Json(specifier.reveal())},
        },
        std::move(options));
}

Result<MutationResult> Client::open_session(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::session_open, std::move(params), std::move(options));
}

Result<Json> Client::notifications(Json::Object params) const {
    return read(Operation::notification_list, std::move(params));
}

Result<MutationResult> Client::notify(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::notification_create,
        std::move(params),
        std::move(options));
}

Result<Json> Client::agents(Json::Object params) const {
    return read(Operation::agent_list, std::move(params));
}

Result<MutationResult> Client::report_agent(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::agent_report, std::move(params), std::move(options));
}

Result<Json> Client::pairing_requests(Json::Object params) const {
    return read(Operation::pairing_request_list, std::move(params));
}

Result<Json> Client::provider_scopes(Json::Object params) const {
    return read(Operation::provider_scope_list, std::move(params));
}

Result<MutationResult> Client::invoke_provider_action(
    ProviderScopeId provider_scope,
    ProviderActionId action,
    Json::Object parameters,
    MutationOptions options) const {
    return mutate(
        Operation::provider_action_invoke,
        Json::Object{
            {"provider_scope", Json(provider_scope.value())},
            {"provider_action", Json(action.value())},
            {"parameters", Json(std::move(parameters))},
        },
        std::move(options));
}

Result<ResourceSnapshot<MachineId>> Machine::refresh() const {
    auto value = read(Operation::machine_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> Machine::sessions() const {
    return read(Operation::session_list);
}

Result<MutationResult> Machine::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::machine_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult> Machine::clear_name(MutationOptions options) const {
    return rename("", std::move(options));
}

Result<MutationResult> Machine::remove(MutationOptions options) const {
    return mutate(Operation::machine_delete, {}, std::move(options));
}

Result<MutationResult> Machine::restore(MutationOptions options) const {
    return mutate(Operation::machine_restore, {}, std::move(options));
}

Result<MutationResult> Machine::purge(MutationOptions options) const {
    return mutate(Operation::machine_purge, {}, std::move(options));
}

Result<ResourceSnapshot<SessionId>> Session::refresh() const {
    auto value = read(Operation::session_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> Session::snapshot() const {
    return read(Operation::session_snapshot);
}

Result<Json> Session::ping() const {
    return read(Operation::session_ping);
}

Result<Json> Session::workspaces() const {
    return read(Operation::workspace_list);
}

Result<MutationResult> Session::create_workspace(
    CreateWorkspaceOptions create,
    MutationOptions mutation) const {
    Json::Object params{
        {"initial_content",
         Json(create.initial_content == InitialContent::terminal ? "terminal"
                                                                 : "empty")},
    };
    if (create.name) {
        params.emplace("name", Json(*create.name));
    }
    return mutate(
        Operation::workspace_create,
        std::move(params),
        std::move(mutation));
}

Result<SessionEventStream> Session::events(
    std::optional<Cursor> cursor) const {
    Json::Object params{{"session", Json(id_.value())}};
    if (cursor) {
        params.emplace("cursor", cursor_json(*cursor));
    }
    auto stream = detail::resource_open_stream(
        state_, Operation::session_events, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionEventStream(std::move(stream).value());
}

Result<MutationResult> Session::shutdown(MutationOptions options) const {
    return mutate(Operation::session_shutdown, {}, std::move(options));
}

Result<MutationResult> Session::reload_config(MutationOptions options) const {
    return mutate(Operation::session_reload_config, {}, std::move(options));
}

Result<MutationResult> Session::update_terminal_defaults(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::session_terminal_defaults_update,
        std::move(params),
        std::move(options));
}

Result<MutationResult> Session::set_window_title(
    std::string title,
    MutationOptions options) const {
    return mutate(
        Operation::session_window_title_set,
        Json::Object{{"title", Json(std::move(title))}},
        std::move(options));
}

Result<MutationResult> Session::clear_window_title(
    MutationOptions options) const {
    return mutate(
        Operation::session_window_title_clear, {}, std::move(options));
}

Result<ResourceSnapshot<WorkspaceId>> Workspace::refresh() const {
    auto value = read(Operation::workspace_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> Workspace::screens() const {
    return read(Operation::screen_list);
}

Result<MutationResult> Workspace::create_screen(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::screen_create, std::move(params), std::move(options));
}

Result<MutationResult> Workspace::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult> Workspace::clear_name(
    MutationOptions options) const {
    // Workspace names are required strings. Empty explicitly clears the label.
    return rename("", std::move(options));
}

Result<MutationResult> Workspace::move(
    std::size_t index,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_move,
        Json::Object{{"index", Json(static_cast<std::uint64_t>(index))}},
        std::move(options));
}

Result<MutationResult> Workspace::focus(MutationOptions options) const {
    return mutate(Operation::workspace_focus, {}, std::move(options));
}

Result<MutationResult> Workspace::close(MutationOptions options) const {
    return mutate(Operation::workspace_close, {}, std::move(options));
}

Result<MutationResult> Workspace::run(
    RunOptions run,
    MutationOptions options) const {
    auto params = run.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::workspace_run,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult> Workspace::apply_layout(
    Json document,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_layout_apply,
        Json::Object{{"layout", std::move(document)}},
        std::move(options));
}

Result<ResourceSnapshot<ScreenId>> Screen::refresh() const {
    auto value = read(Operation::screen_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> Screen::panes() const {
    return read(Operation::pane_list);
}

Result<MutationResult> Screen::create_pane(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::pane_create, std::move(params), std::move(options));
}

Result<MutationResult> Screen::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::screen_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult> Screen::clear_name(MutationOptions options) const {
    return mutate(
        Operation::screen_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult> Screen::focus(MutationOptions options) const {
    return mutate(Operation::screen_focus, {}, std::move(options));
}

Result<MutationResult> Screen::close(MutationOptions options) const {
    return mutate(Operation::screen_close, {}, std::move(options));
}

Result<Json> Screen::export_layout() const {
    return read(Operation::screen_layout_export);
}

Result<MutationResult> Screen::undo_layout(MutationOptions options) const {
    return mutate(Operation::screen_layout_undo, {}, std::move(options));
}

Result<ResourceSnapshot<PaneId>> Pane::refresh() const {
    auto value = read(Operation::pane_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> Pane::tabs() const {
    return read(Operation::tab_list);
}

Result<MutationResult> Pane::split(
    Json::Object params,
    MutationOptions options) const {
    return mutate(Operation::pane_split, std::move(params), std::move(options));
}

Result<MutationResult> Pane::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::pane_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult> Pane::clear_name(MutationOptions options) const {
    return mutate(
        Operation::pane_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult> Pane::focus(MutationOptions options) const {
    return mutate(Operation::pane_focus, {}, std::move(options));
}

Result<MutationResult> Pane::focus_direction(
    std::string direction,
    MutationOptions options) const {
    return mutate(
        Operation::pane_focus_direction,
        Json::Object{{"direction", Json(std::move(direction))}},
        std::move(options));
}

Result<Json> Pane::neighbor(std::string direction) const {
    return read(
        Operation::pane_neighbor_get,
        Json::Object{{"direction", Json(std::move(direction))}});
}

Result<MutationResult> Pane::swap(
    PaneLocation other,
    MutationOptions options) const {
    return mutate(
        Operation::pane_swap,
        Json::Object{
            {"other_workspace", Json(other.workspace.wire())},
            {"other_screen", Json(other.screen.wire())},
            {"other_pane", Json(other.pane.wire())},
        },
        std::move(options));
}

Result<MutationResult> Pane::zoom(
    std::optional<bool> zoomed,
    MutationOptions options) const {
    Json::Object params;
    if (zoomed) {
        params.emplace("enabled", Json(*zoomed));
    }
    return mutate(Operation::pane_zoom, std::move(params), std::move(options));
}

Result<MutationResult> Pane::set_split_ratio(
    SplitId split,
    double ratio,
    MutationOptions options) const {
    return mutate(
        Operation::pane_split_ratio_set,
        Json::Object{
            {"split_id", Json(split.value())},
            {"ratio", Json(ratio)},
        },
        std::move(options));
}

Result<MutationResult> Pane::set_viewport_width(
    std::uint16_t columns,
    MutationOptions options) const {
    return mutate(
        Operation::pane_viewport_width_set,
        Json::Object{{"columns", Json(static_cast<std::uint64_t>(columns))}},
        std::move(options));
}

Result<MutationResult> Pane::close(MutationOptions options) const {
    return mutate(Operation::pane_close, {}, std::move(options));
}

Result<MutationResult> Pane::run(
    RunOptions run,
    MutationOptions options) const {
    auto params = run.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::pane_run,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult> Pane::create_terminal_tab(
    CreateTerminalTabOptions create,
    MutationOptions options) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::tab_create_terminal,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult> Pane::create_browser_tab(
    CreateBrowserTabOptions create,
    MutationOptions options) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::tab_create_browser,
        std::move(params).value(),
        std::move(options));
}

Result<ResourceSnapshot<TabId>> Tab::refresh() const {
    auto value = read(Operation::tab_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<MutationResult> Tab::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::tab_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult> Tab::clear_name(MutationOptions options) const {
    return mutate(
        Operation::tab_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult> Tab::move(
    PaneDestination destination,
    MutationOptions options) const {
    return mutate(
        Operation::tab_move,
        Json::Object{
            {"destination_workspace", Json(destination.workspace.wire())},
            {"destination_screen", Json(destination.screen.wire())},
            {"destination_pane", Json(destination.pane.wire())},
            {"index", Json(static_cast<std::uint64_t>(destination.index))},
        },
        std::move(options));
}

Result<MutationResult> Tab::focus(MutationOptions options) const {
    return mutate(Operation::tab_focus, {}, std::move(options));
}

Result<MutationResult> Tab::close(MutationOptions options) const {
    return mutate(Operation::tab_close, {}, std::move(options));
}

Result<ResourceSnapshot<TerminalId>> Terminal::refresh() const {
    auto value = read(Operation::terminal_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<MutationResult> Terminal::write(
    std::string text,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_write,
        Json::Object{{"text", Json(std::move(text))}},
        std::move(options));
}

Result<MutationResult> Terminal::keys(
    std::vector<std::string> keys,
    MutationOptions options) const {
    Json::Array encoded;
    encoded.reserve(keys.size());
    for (auto& key : keys) {
        encoded.emplace_back(std::move(key));
    }
    return mutate(
        Operation::terminal_input_keys,
        Json::Object{{"keys", Json(std::move(encoded))}},
        std::move(options));
}

Result<MutationResult> Terminal::mouse(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_mouse,
        std::move(params),
        std::move(options));
}

Result<MutationResult> Terminal::input_focus(
    bool focused,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_focus,
        Json::Object{{"focused", Json(focused)}},
        std::move(options));
}

Result<Json> Terminal::read_screen(Json::Object params) const {
    return read(Operation::terminal_screen_read, std::move(params));
}

Result<Json> Terminal::read_state() const {
    return read(Operation::terminal_state_read);
}

Result<Json> Terminal::read_history(Json::Object params) const {
    return read(Operation::terminal_history_read, std::move(params));
}

Result<MutationResult> Terminal::clear_history(
    MutationOptions options) const {
    return mutate(
        Operation::terminal_history_clear, {}, std::move(options));
}

Result<Json> Terminal::wait(
    std::string pattern,
    std::optional<std::uint64_t> timeout_ms) const {
    if (pattern.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "terminal wait pattern must not be empty");
    }
    Json::Object params{{"pattern", Json(std::move(pattern))}};
    if (timeout_ms) {
        params.emplace("timeout_ms", Json(std::to_string(*timeout_ms)));
    }
    return read(Operation::terminal_wait, std::move(params));
}

Result<Json> Terminal::copy(Json::Object params) const {
    return read(Operation::terminal_copy, std::move(params));
}

Result<Json> Terminal::process() const {
    return read(Operation::terminal_process_get);
}

Result<RendererGrant> Terminal::renderer_grant(Json::Object params) const {
    params.insert_or_assign("terminal", Json(id_.value()));
    auto result = detail::resource_control(
        state_,
        Operation::terminal_renderer_grant_create,
        std::move(params));
    if (!result) {
        return std::move(result).error();
    }
    auto endpoint = require_string(result.value(), "endpoint");
    auto terminal_id_text = require_string(result.value(), "terminal_id");
    auto token = require_string(result.value(), "token");
    if (!endpoint || !terminal_id_text || !token || token.value().empty()) {
        return make_error(ErrorCode::decode, "renderer grant is incomplete");
    }
    auto terminal_id = TerminalId::parse(terminal_id_text.value());
    if (!terminal_id) {
        return std::move(terminal_id).error();
    }
    const Json* ttl_value = result.value().find("ttl_ms");
    const Json* rights_value = result.value().find("rights");
    if (!ttl_value || !rights_value) {
        return make_error(ErrorCode::decode, "renderer grant is incomplete");
    }
    auto ttl = decimal_u64(*ttl_value, "renderer ttl_ms");
    auto rights_array = rights_value->as_array();
    if (!ttl || !rights_array || ttl.value() == 0 ||
        ttl.value() > std::numeric_limits<std::uint32_t>::max() ||
        rights_array.value()->empty()) {
        return make_error(ErrorCode::decode, "renderer grant is invalid");
    }
    std::vector<std::string> rights;
    rights.reserve(rights_array.value()->size());
    for (const auto& right : *rights_array.value()) {
        auto text = right.as_string();
        if (!text) {
            return make_error(
                ErrorCode::decode,
                "renderer grant rights must be strings");
        }
        rights.emplace_back(text.value());
    }
    return RendererGrant{
        std::move(endpoint).value(),
        std::move(terminal_id).value(),
        SensitiveString(std::move(token).value()),
        std::move(rights),
        static_cast<std::uint32_t>(ttl.value()),
    };
}

Result<Json> Terminal::resize_viewer(
    std::uint16_t columns,
    std::uint16_t rows) const {
    if (columns == 0 || rows == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "terminal cell dimensions must be positive");
    }
    return detail::resource_control(
        state_,
        Operation::terminal_viewer_resize,
        Json::Object{
            {"terminal", Json(id_.value())},
            {"cols", Json(static_cast<std::uint64_t>(columns))},
            {"rows", Json(static_cast<std::uint64_t>(rows))},
        });
}

Result<Json> Terminal::release_viewer() const {
    return detail::resource_control(
        state_,
        Operation::terminal_viewer_release,
        Json::Object{{"terminal", Json(id_.value())}});
}

Result<MutationResult> Terminal::scroll(
    std::int32_t delta_rows,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_viewport_scroll,
        Json::Object{{"delta_rows", Json(static_cast<std::int64_t>(delta_rows))}},
        std::move(options));
}

Result<MutationResult> Terminal::move(
    PaneDestination destination,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_move,
        Json::Object{
            {"destination_workspace", Json(destination.workspace.wire())},
            {"destination_screen", Json(destination.screen.wire())},
            {"destination_pane", Json(destination.pane.wire())},
            {"index", Json(static_cast<std::uint64_t>(destination.index))},
        },
        std::move(options));
}

Result<TerminalAttachmentStream> Terminal::attach(
    Json::Object params) const {
    params.insert_or_assign("terminal", Json(id_.value()));
    auto stream = detail::resource_open_stream(
        state_, Operation::terminal_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return TerminalAttachmentStream(std::move(stream).value());
}

Result<MutationResult> Terminal::close(MutationOptions options) const {
    return mutate(Operation::terminal_close, {}, std::move(options));
}

Result<ResourceSnapshot<BrowserId>> Browser::refresh() const {
    auto value = read(Operation::browser_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<MutationResult> Browser::navigate(
    std::string url,
    MutationOptions options) const {
    return mutate(
        Operation::browser_navigate,
        Json::Object{{"url", Json(std::move(url))}},
        std::move(options));
}

Result<MutationResult> Browser::back(MutationOptions options) const {
    return mutate(Operation::browser_back, {}, std::move(options));
}

Result<MutationResult> Browser::forward(MutationOptions options) const {
    return mutate(Operation::browser_forward, {}, std::move(options));
}

Result<MutationResult> Browser::reload(MutationOptions options) const {
    return mutate(Operation::browser_reload, {}, std::move(options));
}

Result<MutationResult> Browser::activate(MutationOptions options) const {
    return mutate(Operation::browser_activate, {}, std::move(options));
}

Result<MutationResult> Browser::key(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_key, std::move(params), std::move(options));
}

Result<MutationResult> Browser::text(
    std::string text,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_text,
        Json::Object{{"text", Json(std::move(text))}},
        std::move(options));
}

Result<MutationResult> Browser::mouse(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_mouse,
        std::move(params),
        std::move(options));
}

Result<MutationResult> Browser::wheel(
    double delta_x,
    double delta_y,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_wheel,
        Json::Object{
            {"delta_x", Json(delta_x)},
            {"delta_y", Json(delta_y)},
        },
        std::move(options));
}

Result<Json> Browser::resize_viewer(
    std::uint32_t width_px,
    std::uint32_t height_px) const {
    if (width_px == 0 || height_px == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "browser pixel dimensions must be positive");
    }
    return detail::resource_control(
        state_,
        Operation::browser_viewer_resize,
        Json::Object{
            {"browser", Json(id_.value())},
            {"width_px", Json(static_cast<std::uint64_t>(width_px))},
            {"height_px", Json(static_cast<std::uint64_t>(height_px))},
        });
}

Result<Json> Browser::release_viewer() const {
    return detail::resource_control(
        state_,
        Operation::browser_viewer_release,
        Json::Object{{"browser", Json(id_.value())}});
}

Result<BrowserAttachmentStream> Browser::attach(
    Json::Object params) const {
    params.insert_or_assign("browser", Json(id_.value()));
    auto stream = detail::resource_open_stream(
        state_, Operation::browser_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return BrowserAttachmentStream(std::move(stream).value());
}

Result<MutationResult> Browser::close(MutationOptions options) const {
    return mutate(Operation::browser_close, {}, std::move(options));
}

Result<ResourceSnapshot<ConnectedClientId>> ConnectedClient::refresh() const {
    auto value = read(Operation::client_get);
    if (!value) {
        return std::move(value).error();
    }
    return decode_snapshot(std::move(value).value(), id_);
}

Result<Json> ConnectedClient::update_metadata(
    ClientMetadataUpdate update) const {
    Json::Object params{{"client", Json(id_.value())}};
    const auto add = [&params](
                         std::string key,
                         const OptionalStringUpdate& value) {
        switch (value.state()) {
            case OptionalStringUpdate::State::unchanged:
                break;
            case OptionalStringUpdate::State::set:
                params.emplace(std::move(key), Json(value.value()));
                break;
            case OptionalStringUpdate::State::clear:
                params.emplace(std::move(key), Json(nullptr));
                break;
        }
    };
    add("name", update.name);
    add("kind", update.kind);
    if (params.size() == 1) {
        return make_error(
            ErrorCode::invalid_argument,
            "client metadata update must change name or kind");
    }
    return detail::resource_control(
        state_,
        Operation::client_metadata_update,
        std::move(params));
}

Result<Json> ConnectedClient::set_name(std::string name) const {
    return update_metadata(
        ClientMetadataUpdate{.name = OptionalStringUpdate::set(
                                 std::move(name))});
}

Result<Json> ConnectedClient::clear_name() const {
    return update_metadata(
        ClientMetadataUpdate{.name = OptionalStringUpdate::clear()});
}

Result<Json> ConnectedClient::set_kind(std::string kind) const {
    return update_metadata(
        ClientMetadataUpdate{.kind = OptionalStringUpdate::set(
                                 std::move(kind))});
}

Result<Json> ConnectedClient::clear_kind() const {
    return update_metadata(
        ClientMetadataUpdate{.kind = OptionalStringUpdate::clear()});
}

Result<Json> ConnectedClient::set_sizing(Json::Object params) const {
    params.insert_or_assign("client", Json(id_.value()));
    return detail::resource_control(
        state_, Operation::client_sizing_set, std::move(params));
}

Result<Json> ConnectedClient::release_sizing(Json::Object params) const {
    params.insert_or_assign("client", Json(id_.value()));
    return detail::resource_control(
        state_, Operation::client_sizing_release, std::move(params));
}

Result<Json> ConnectedClient::set_cell_pixels(
    std::uint32_t width_px,
    std::uint32_t height_px) const {
    if (width_px == 0 || height_px == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "cell pixel dimensions must be positive");
    }
    return detail::resource_control(
        state_,
        Operation::client_cell_pixels_set,
        Json::Object{
            {"client", Json(id_.value())},
            {"width_px", Json(static_cast<std::uint64_t>(width_px))},
            {"height_px", Json(static_cast<std::uint64_t>(height_px))},
        });
}

Result<Json> ConnectedClient::detach() const {
    return detail::resource_control(
        state_,
        Operation::client_detach,
        Json::Object{{"client", Json(id_.value())}});
}

Result<Json> SidebarView::refresh() const {
    return read(Operation::sidebar_view_get);
}

Result<SidebarViewStream> SidebarView::attach(
    Json::Object params) const {
    params.insert_or_assign("sidebar_view", Json(id_.value()));
    auto stream = detail::resource_open_stream(
        state_, Operation::sidebar_view_attach, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return SidebarViewStream(std::move(stream).value());
}

Result<MutationResult> ProviderScope::create_machine(
    MutationOptions options) const {
    return mutate(Operation::machine_create, {}, std::move(options));
}

Result<MutationResult> ProviderScope::connect_external(
    const SensitiveString& specifier,
    MutationOptions options) const {
    return mutate(
        Operation::machine_connect_external,
        Json::Object{{"specifier", Json(specifier.reveal())}},
        std::move(options));
}

Result<MutationResult> ProviderScope::invoke(
    ProviderActionId action,
    Json::Object parameters,
    MutationOptions options) const {
    return mutate(
        Operation::provider_action_invoke,
        Json::Object{
            {"provider_action", Json(action.value())},
            {"parameters", Json(std::move(parameters))},
        },
        std::move(options));
}

Result<ProviderNoticeStream> ProviderScope::notices(
    std::optional<Cursor> cursor) const {
    Json::Object params{{"provider_scope", Json(id_.value())}};
    if (cursor) {
        params.emplace("cursor", cursor_json(*cursor));
    }
    auto stream = detail::resource_open_stream(
        state_, Operation::provider_notice_events, std::move(params));
    if (!stream) {
        return std::move(stream).error();
    }
    return ProviderNoticeStream(std::move(stream).value());
}

ProviderNoticeHandle ProviderScope::notice(ProviderNoticeId id) const {
    return ProviderNoticeHandle(
        state_,
        std::move(id),
        "provider_notice",
        id_);
}

Result<MutationResult> ProviderScope::mark_workspace(
    SessionId session,
    WorkspaceId workspace,
    bool managed,
    MutationOptions options) const {
    return mutate(
        Operation::provider_workspace_mark,
        Json::Object{
            {"session", Json(session.value())},
            {"workspace", Json(workspace.value())},
            {"managed", Json(managed)},
        },
        std::move(options));
}

Result<MutationResult> ProviderScope::rename_workspace(
    SessionId session,
    WorkspaceId workspace,
    std::optional<std::string> name,
    MutationOptions options) const {
    return mutate(
        Operation::provider_workspace_rename,
        Json::Object{
            {"session", Json(session.value())},
            {"workspace", Json(workspace.value())},
            {"name", name ? Json(*name) : Json(nullptr)},
        },
        std::move(options));
}

Result<MutationResult> ProviderScope::close_workspace(
    SessionId session,
    WorkspaceId workspace,
    MutationOptions options) const {
    return mutate(
        Operation::provider_workspace_close,
        Json::Object{
            {"session", Json(session.value())},
            {"workspace", Json(workspace.value())},
        },
        std::move(options));
}

Result<Json> ProviderNoticeHandle::acknowledge(
    std::uint64_t sequence) const {
    Json::Object params{
        {"provider_notice", Json(id_.value())},
        {"sequence", Json(std::to_string(sequence))},
    };
    if (provider_scope_) {
        params.emplace(
            "provider_scope",
            Json(provider_scope_->value()));
    }
    return detail::resource_control(
        state_,
        Operation::provider_notice_acknowledge,
        std::move(params));
}

#undef CMUX_OPERATION_TABLE

namespace {

[[nodiscard]] Error decode_embedded_error(
    const Json& error,
    const Json& envelope) {
    Error decoded = make_error(ErrorCode::command, "cmux stream failed");
    decoded.response = std::make_shared<Json>(redact_json(envelope));
    if (!error.is_object()) {
        return decoded;
    }
    if (const Json* code = error.find("code")) {
        if (auto text = code->as_string()) {
            decoded.protocol_code = std::string(text.value());
        }
    }
    if (const Json* message = error.find("message")) {
        if (auto text = message->as_string()) {
            decoded.message = std::string(text.value());
        }
    }
    if (const Json* details = error.find("details")) {
        decoded.details = std::make_shared<Json>(redact_json(*details));
    }
    if (const Json* retryable = error.find("retryable")) {
        if (auto boolean = retryable->as_bool()) {
            decoded.retryable = boolean.value();
        }
    }
    return decoded;
}

[[nodiscard]] Result<StreamEnd> decode_stream_end(
    const Json& envelope,
    const StreamId& expected_stream) {
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/1") {
        return make_error(
            ErrorCode::protocol,
            "stream end protocol must be cmux.protocol/1");
    }
    auto type = require_string(envelope, "type");
    if (!type || type.value() != "stream_end") {
        return make_error(ErrorCode::protocol, "expected stream_end envelope");
    }
    auto stream_id = require_string(envelope, "stream_id");
    if (!stream_id || stream_id.value() != expected_stream.value()) {
        return make_error(ErrorCode::protocol, "stream end ID mismatch");
    }
    auto reason = require_string(envelope, "reason");
    if (!reason) {
        return std::move(reason).error();
    }
    StreamEnd decoded;
    if (reason.value() == "completed") {
        decoded.reason = StreamEndReason::completed;
    } else if (reason.value() == "canceled") {
        decoded.reason = StreamEndReason::canceled;
    } else if (reason.value() == "closed") {
        decoded.reason = StreamEndReason::closed;
    } else if (reason.value() == "gap") {
        decoded.reason = StreamEndReason::gap;
    } else if (reason.value() == "error") {
        decoded.reason = StreamEndReason::error;
    } else {
        return make_error(ErrorCode::decode, "unknown stream end reason");
    }
    if (const Json* cursor = envelope.find("cursor");
        cursor && !cursor->is_null()) {
        auto parsed = parse_cursor(*cursor);
        if (!parsed) {
            return std::move(parsed).error();
        }
        decoded.cursor = std::move(parsed).value();
    }
    if (const Json* recovery = envelope.find("recovery");
        recovery && !recovery->is_null()) {
        if (auto text = recovery->as_string()) {
            decoded.recovery = std::string(text.value());
        } else {
            auto encoded = recovery->encode();
            if (!encoded) {
                return std::move(encoded).error();
            }
            decoded.recovery = std::move(encoded).value();
        }
    }
    if (const Json* error = envelope.find("error");
        error && !error->is_null()) {
        decoded.error = decode_embedded_error(*error, envelope);
    }
    return decoded;
}

[[nodiscard]] Result<RawStreamItem> decode_stream_item(
    const Json& envelope,
    const StreamId& expected_stream) {
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/1") {
        return make_error(
            ErrorCode::protocol,
            "stream item protocol must be cmux.protocol/1");
    }
    auto type = require_string(envelope, "type");
    if (!type || type.value() != "stream_item") {
        return make_error(ErrorCode::protocol, "expected stream_item envelope");
    }
    auto stream_id = require_string(envelope, "stream_id");
    if (!stream_id || stream_id.value() != expected_stream.value()) {
        return make_error(ErrorCode::protocol, "stream item ID mismatch");
    }
    const Json* sequence = envelope.find("sequence");
    if (!sequence) {
        return make_error(ErrorCode::decode, "stream item is missing sequence");
    }
    auto parsed_sequence = decimal_u64(*sequence, "stream sequence");
    if (!parsed_sequence) {
        return std::move(parsed_sequence).error();
    }
    const Json* item = envelope.find("item");
    if (!item) {
        return make_error(ErrorCode::decode, "stream item is missing item");
    }
    RawStreamItem decoded;
    decoded.sequence = parsed_sequence.value();
    decoded.value = *item;
    if (const Json* cursor = envelope.find("cursor");
        cursor && !cursor->is_null()) {
        auto parsed = parse_cursor(*cursor);
        if (!parsed) {
            return std::move(parsed).error();
        }
        decoded.cursor = std::move(parsed).value();
    }
    return decoded;
}

[[nodiscard]] Result<std::string> envelope_type(const Json& envelope) {
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/1") {
        return make_error(
            ErrorCode::protocol,
            "server protocol must be cmux.protocol/1");
    }
    return require_string(envelope, "type");
}

}  // namespace

struct ResourceStream::Impl {
    std::unique_ptr<Transport> transport;
    ClientOptions options;
    StreamId stream_id;
    std::deque<Json> buffered;
    std::optional<StreamEnd> stream_end;
    std::atomic<std::uint64_t> next_request_id{1};
    std::mutex mutex;
    bool transport_closed = false;

    [[nodiscard]] Result<Json> receive() {
        auto wire = transport->receive(options.timeout);
        if (!wire) {
            return std::move(wire).error();
        }
        return Json::parse(wire.value(), options.json_limits);
    }

    [[nodiscard]] std::string request_id(std::string_view purpose) {
        return "cpp-stream-" + std::string(purpose) + "-" +
               std::to_string(
                   next_request_id.fetch_add(1, std::memory_order_relaxed));
    }

    void close_transport() noexcept {
        if (!transport_closed) {
            transport_closed = true;
            transport->close();
        }
    }
};

Result<std::unique_ptr<ResourceStream::Impl>>
detail::ResourceClientState::open_stream(
    Operation operation,
    Json::Object params) {
    if (!stream_factory) {
        return make_error(
            ErrorCode::unsupported,
            "this client has no stream transport factory");
    }
    auto transport_result = stream_factory();
    if (!transport_result) {
        return std::move(transport_result).error();
    }
    auto stream_value = make_stream_value();
    auto parsed_id = StreamId::parse(stream_value);
    if (!parsed_id) {
        return std::move(parsed_id).error();
    }
    params.insert_or_assign("stream_id", Json(stream_value));
    inject_routing(options, operation, params);
    auto impl = std::make_unique<ResourceStream::Impl>();
    impl->transport = std::move(transport_result).value();
    impl->options = options;
    impl->stream_id = std::move(parsed_id).value();
    const auto request_id = impl->request_id("open");
    auto sent = send_envelope(
        *impl->transport,
        request_id,
        operation,
        std::move(params),
        std::nullopt,
        options.timeout,
        options.json_limits);
    if (!sent) {
        return std::move(sent).error();
    }
    while (true) {
        auto envelope = impl->receive();
        if (!envelope) {
            return std::move(envelope).error();
        }
        auto type = envelope_type(envelope.value());
        if (!type) {
            return std::move(type).error();
        }
        if (type.value() == "response") {
            const Json* id = envelope.value().find("id");
            if (!id) {
                continue;
            }
            auto text = id->as_string();
            if (!text || text.value() != request_id) {
                continue;
            }
            auto response = decode_response(envelope.value(), request_id);
            if (!response) {
                return std::move(response).error();
            }
            return impl;
        }
        const Json* stream_id = envelope.value().find("stream_id");
        if (!stream_id) {
            continue;
        }
        auto text = stream_id->as_string();
        if (!text || text.value() != impl->stream_id.value()) {
            continue;
        }
        if (type.value() == "stream_item" || type.value() == "stream_end") {
            impl->buffered.push_back(std::move(envelope).value());
        }
    }
}

ResourceStream::ResourceStream(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

ResourceStream::ResourceStream(ResourceStream&&) noexcept = default;
ResourceStream& ResourceStream::operator=(ResourceStream&&) noexcept = default;

ResourceStream::~ResourceStream() {
    if (impl_) {
        // Dropping a stream only closes its connection. It never deletes a
        // session resource and never hides a failed cancellation.
        impl_->close_transport();
    }
}

const StreamId& ResourceStream::id() const noexcept {
    static const StreamId empty;
    return impl_ ? impl_->stream_id : empty;
}

Result<std::optional<RawStreamItem>> ResourceStream::next() {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    return next(impl_->options.timeout);
}

Result<std::optional<RawStreamItem>> ResourceStream::next(Timeout timeout) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    std::lock_guard lock(impl_->mutex);
    if (impl_->stream_end) {
        return std::optional<RawStreamItem>{};
    }
    Json envelope;
    if (!impl_->buffered.empty()) {
        envelope = std::move(impl_->buffered.front());
        impl_->buffered.pop_front();
    } else {
        auto wire = impl_->transport->receive(timeout);
        if (!wire) {
            return std::move(wire).error();
        }
        auto parsed = Json::parse(wire.value(), impl_->options.json_limits);
        if (!parsed) {
            return std::move(parsed).error();
        }
        envelope = std::move(parsed).value();
    }
    auto type = envelope_type(envelope);
    if (!type) {
        return std::move(type).error();
    }
    if (type.value() == "stream_end") {
        auto end = decode_stream_end(envelope, impl_->stream_id);
        if (!end) {
            return std::move(end).error();
        }
        impl_->stream_end = std::move(end).value();
        impl_->close_transport();
        return std::optional<RawStreamItem>{};
    }
    if (type.value() != "stream_item") {
        return make_error(
            ErrorCode::protocol,
            "stream connection received an unexpected envelope");
    }
    auto item = decode_stream_item(envelope, impl_->stream_id);
    if (!item) {
        return std::move(item).error();
    }
    return std::optional<RawStreamItem>(std::move(item).value());
}

Result<Json> ResourceStream::connection_control(
    Operation operation,
    Json::Object params) {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    if (operation_class(operation) != OperationClass::connection_control) {
        return wrong_class(operation, OperationClass::connection_control);
    }
    std::lock_guard lock(impl_->mutex);
    if (impl_->transport_closed) {
        return make_error(ErrorCode::closed, "stream is closed");
    }
    const auto request_id = impl_->request_id("control");
    inject_routing(impl_->options, operation, params);
    auto sent = detail::ResourceClientState::send_envelope(
        *impl_->transport,
        request_id,
        operation,
        std::move(params),
        std::nullopt,
        impl_->options.timeout,
        impl_->options.json_limits);
    if (!sent) {
        return std::move(sent).error();
    }
    while (true) {
        auto envelope = impl_->receive();
        if (!envelope) {
            return std::move(envelope).error();
        }
        auto type = envelope_type(envelope.value());
        if (!type) {
            return std::move(type).error();
        }
        if (type.value() == "response") {
            const Json* id = envelope.value().find("id");
            if (id) {
                auto text = id->as_string();
                if (text && text.value() == request_id) {
                    return decode_response(envelope.value(), request_id);
                }
            }
            continue;
        }
        if (type.value() == "stream_item" || type.value() == "stream_end") {
            impl_->buffered.push_back(std::move(envelope).value());
        }
    }
}

Result<StreamEnd> ResourceStream::cancel() {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    std::lock_guard lock(impl_->mutex);
    if (impl_->stream_end) {
        return *impl_->stream_end;
    }
    if (impl_->transport_closed) {
        return make_error(ErrorCode::closed, "stream connection is closed");
    }
    const auto request_id = impl_->request_id("cancel");
    Json::Object params{{"stream_id", Json(impl_->stream_id.value())}};
    inject_routing(impl_->options, Operation::stream_cancel, params);
    auto sent = detail::ResourceClientState::send_envelope(
        *impl_->transport,
        request_id,
        Operation::stream_cancel,
        std::move(params),
        std::nullopt,
        impl_->options.timeout,
        impl_->options.json_limits);
    if (!sent) {
        return std::move(sent).error();
    }
    bool response_seen = false;
    std::optional<StreamEnd> end;
    while (!response_seen || !end) {
        Json envelope;
        if (!impl_->buffered.empty()) {
            envelope = std::move(impl_->buffered.front());
            impl_->buffered.pop_front();
        } else {
            auto received = impl_->receive();
            if (!received) {
                return std::move(received).error();
            }
            envelope = std::move(received).value();
        }
        auto type = envelope_type(envelope);
        if (!type) {
            return std::move(type).error();
        }
        if (type.value() == "response") {
            const Json* id = envelope.find("id");
            if (!id) {
                continue;
            }
            auto text = id->as_string();
            if (!text || text.value() != request_id) {
                continue;
            }
            auto response = decode_response(envelope, request_id);
            if (!response) {
                return std::move(response).error();
            }
            response_seen = true;
            continue;
        }
        if (type.value() == "stream_end") {
            auto decoded = decode_stream_end(envelope, impl_->stream_id);
            if (!decoded) {
                return std::move(decoded).error();
            }
            end = std::move(decoded).value();
        }
        // Items already queued before cancellation are intentionally dropped.
    }
    impl_->stream_end = std::move(end);
    impl_->close_transport();
    return *impl_->stream_end;
}

bool ResourceStream::closed() const noexcept {
    return !impl_ || impl_->transport_closed || impl_->stream_end.has_value();
}

const std::optional<StreamEnd>& ResourceStream::end() const noexcept {
    static const std::optional<StreamEnd> empty;
    return impl_ ? impl_->stream_end : empty;
}

namespace detail {

Result<ResourceStream> resource_open_stream(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::stream_open) {
        return wrong_class(operation, OperationClass::stream_open);
    }
    auto opened = state->open_stream(operation, std::move(params));
    if (!opened) {
        return std::move(opened).error();
    }
    return ResourceStream(std::move(opened).value());
}

}  // namespace detail

}  // namespace cmux
