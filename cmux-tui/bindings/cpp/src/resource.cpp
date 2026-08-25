#include "cmux/resource.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <random>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if defined(CMUX_CPP_TESTING)
#include "resource_test_hooks.hpp"
#endif

#include "socket_path_internal.hpp"

#if defined(__APPLE__)
#include <stdlib.h>
#elif defined(__linux__)
#include <sys/random.h>
#endif

namespace cmux {

#if defined(CMUX_CPP_TESTING)
namespace detail {
namespace {

std::atomic<std::size_t> simulated_request_lock_failures{0};
std::atomic<std::size_t> observed_request_lock_failures{0};

}  // namespace

void simulate_spurious_request_lock_failures(std::size_t count) noexcept {
    observed_request_lock_failures.store(0, std::memory_order_release);
    simulated_request_lock_failures.store(count, std::memory_order_release);
}

std::size_t simulated_request_lock_failures_observed() noexcept {
    return observed_request_lock_failures.load(std::memory_order_acquire);
}

bool consume_simulated_request_lock_failure() noexcept {
    auto remaining =
        simulated_request_lock_failures.load(std::memory_order_acquire);
    while (remaining != 0) {
        if (simulated_request_lock_failures.compare_exchange_weak(
                remaining,
                remaining - 1,
                std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            observed_request_lock_failures.fetch_add(
                1,
                std::memory_order_release);
            return true;
        }
    }
    return false;
}

}  // namespace detail
#endif

namespace {

struct OperationInfo {
    std::string_view name;
    OperationClass operation_class;
};

#define CMUX_OPERATION_TABLE(X)                                                       \
    X(machine_list, "machine.list", read)                                             \
    X(machine_get, "machine.get", read)                                               \
    X(session_list, "session.list", read)                                             \
    X(session_open, "session.open", mutation)                                         \
    X(session_get, "session.get", read)                                               \
    X(session_snapshot, "session.snapshot", read)                                     \
    X(session_creation_resolve, "session.creation.resolve", read)                     \
    X(session_events, "session.events", stream_open)                                  \
    X(session_journal_subscribe, "session.journal.subscribe", stream_open)            \
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
    X(request_cancel, "request.cancel", connection_control)                           \
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
    X(terminal_wait_exit, "terminal.wait_exit", read)                                 \
    X(terminal_copy, "terminal.copy", read)                                           \
    X(terminal_process_get, "terminal.process.get", read)                             \
    X(terminal_renderer_grant_create, "terminal.renderer_grant.create",               \
      connection_control)                                                             \
    X(terminal_viewer_resize, "terminal.viewer.resize", connection_control)           \
    X(terminal_viewer_release, "terminal.viewer.release", connection_control)         \
    X(terminal_viewport_scroll, "terminal.viewport.scroll", mutation)                 \
    X(terminal_move, "terminal.move", mutation)                                       \
    X(terminal_project, "terminal.project", mutation)                                 \
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
        case Operation::request_cancel:
            return false;
        default:
            return true;
    }
}

[[nodiscard]] bool requires_session(Operation operation) noexcept {
    switch (operation) {
        case Operation::machine_list:
        case Operation::machine_get:
        case Operation::session_list:
        case Operation::request_cancel:
            return false;
        default:
            return true;
    }
}

[[nodiscard]] bool supports_expected_revision(Operation operation) noexcept {
    return info_for(operation).operation_class == OperationClass::mutation;
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
    if (auto text = value.as_string()) {
        if (text.value().empty() ||
            (text.value().size() > 1U && text.value().front() == '0')) {
            return make_error(
                ErrorCode::decode,
                std::string(context) +
                    " must be a canonical decimal string");
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

[[nodiscard]] Result<void> require_exact_fields(
    const Json& value,
    std::initializer_list<std::string_view> allowed,
    std::string_view context);

[[nodiscard]] Result<Cursor> parse_cursor(const Json& value) {
    auto object = value.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "cursor must be an object");
    }
    auto exact = require_exact_fields(
        value, {"generation", "revision"}, "cursor");
    if (!exact) {
        return std::move(exact).error();
    }
    auto generation = require_string(value, "generation");
    if (!generation || generation.value().empty() ||
        generation.value().size() > 128U) {
        return make_error(
            ErrorCode::decode,
            "cursor generation must contain 1 to 128 bytes");
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

[[nodiscard]] Result<void> require_exact_fields(
    const Json& value,
    std::initializer_list<std::string_view> allowed,
    std::string_view context) {
    auto object = value.as_object();
    if (!object) {
        return make_error(
            ErrorCode::decode,
            std::string(context) + " must be an object");
    }
    for (const auto& [key, item] : *object.value()) {
        static_cast<void>(item);
        if (std::find(allowed.begin(), allowed.end(), key) == allowed.end()) {
            return make_error(
                ErrorCode::decode,
                std::string(context) + " contains unknown field '" + key + "'");
        }
    }
    return {};
}

[[nodiscard]] Result<RawMutationResult> decode_mutation(Json result) {
    auto object = result.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "mutation result must be an object");
    }
    auto exact = require_exact_fields(
        result,
        {"value", "generation", "revision", "replayed"},
        "mutation result");
    if (!exact) {
        return std::move(exact).error();
    }
    RawMutationResult decoded;
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
    std::string_view request_id,
    std::string_view context = "response") {
    auto object = response.as_object();
    if (!object) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " must be an object");
    }
    auto protocol = require_string(response, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/2") {
        return make_error(
            ErrorCode::protocol,
            std::string(context) +
                " protocol must be cmux.protocol/2");
    }
    auto type = require_string(response, "type");
    if (!type || type.value() != "response") {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " type must be response");
    }
    auto id = require_string(response, "id");
    if (!id || id.value() != request_id) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " request ID mismatch");
    }
    const Json* ok = response.find("ok");
    if (!ok) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " is missing ok");
    }
    auto succeeded = ok->as_bool();
    if (!succeeded) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " ok must be boolean");
    }
    auto exact = succeeded.value()
                     ? require_exact_fields(
                           response,
                           {"protocol", "type", "id", "ok", "result"},
                           context)
                     : require_exact_fields(
                           response,
                           {"protocol", "type", "id", "ok", "error"},
                           context);
    if (!exact) {
        auto error = std::move(exact).error();
        error.code = ErrorCode::protocol;
        return error;
    }
    if (succeeded.value()) {
        const Json* result = response.find("result");
        if (!result) {
            return make_error(
                ErrorCode::protocol,
                std::string(context) + " is missing result");
        }
        return *result;
    }
    const Json* payload = response.find("error");
    if (!payload) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) + " is missing error");
    }
    auto payload_exact = require_exact_fields(
        *payload,
        {"code", "message", "details", "retryable"},
        "response error");
    if (!payload_exact) {
        auto error = std::move(payload_exact).error();
        error.code = ErrorCode::protocol;
        return error;
    }
    auto code = require_string(*payload, "code");
    auto message = require_string(*payload, "message");
    const Json* details = payload->find("details");
    const Json* retryable = payload->find("retryable");
    if (!code || !message || !details || !retryable ||
        !retryable->as_bool()) {
        return make_error(
            ErrorCode::protocol,
            std::string(context) +
                " error must contain string code and message, details, "
                "and boolean retryable");
    }
    return protocol_error(response);
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

[[nodiscard]] Result<void> put_correlation_key(
    Json::Object& params,
    const std::optional<std::string>& correlation_key) {
    if (!correlation_key) {
        return {};
    }
    if (correlation_key->empty() || correlation_key->size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "correlation_key must contain 1 to 128 UTF-8 bytes");
    }
    params.emplace("correlation_key", Json(*correlation_key));
    return {};
}

[[nodiscard]] bool unicode_whitespace(std::uint32_t codepoint) noexcept {
    return (codepoint >= 0x0009U && codepoint <= 0x000DU) ||
           codepoint == 0x0020U || codepoint == 0x0085U ||
           codepoint == 0x00A0U || codepoint == 0x1680U ||
           (codepoint >= 0x2000U && codepoint <= 0x200AU) ||
           codepoint == 0x2028U || codepoint == 0x2029U ||
           codepoint == 0x202FU || codepoint == 0x205FU ||
           codepoint == 0x3000U;
}

[[nodiscard]] bool unicode_control(std::uint32_t codepoint) noexcept {
    return codepoint <= 0x001FU ||
           (codepoint >= 0x007FU && codepoint <= 0x009FU);
}

[[nodiscard]] Result<void> validate_idempotency_key(
    std::string_view value) {
    if (value.empty() || value.size() > 128U) {
        return make_error(
            ErrorCode::invalid_argument,
            "idempotency key must contain 1 to 128 UTF-8 bytes");
    }
    bool has_non_whitespace = false;
    for (std::size_t index = 0; index < value.size();) {
        const auto first = static_cast<unsigned char>(value[index]);
        std::size_t length = 0;
        std::uint32_t codepoint = 0;
        std::uint32_t minimum = 0;
        if (first <= 0x7FU) {
            length = 1;
            codepoint = first;
        } else if (first >= 0xC2U && first <= 0xDFU) {
            length = 2;
            codepoint = first & 0x1FU;
            minimum = 0x80U;
        } else if (first >= 0xE0U && first <= 0xEFU) {
            length = 3;
            codepoint = first & 0x0FU;
            minimum = 0x800U;
        } else if (first >= 0xF0U && first <= 0xF4U) {
            length = 4;
            codepoint = first & 0x07U;
            minimum = 0x10000U;
        } else {
            return make_error(
                ErrorCode::invalid_argument,
                "idempotency key must contain valid Unicode scalars");
        }
        if (index + length > value.size()) {
            return make_error(
                ErrorCode::invalid_argument,
                "idempotency key must contain valid Unicode scalars");
        }
        for (std::size_t offset = 1; offset < length; ++offset) {
            const auto next = static_cast<unsigned char>(value[index + offset]);
            if ((next & 0xC0U) != 0x80U) {
                return make_error(
                    ErrorCode::invalid_argument,
                    "idempotency key must contain valid Unicode scalars");
            }
            codepoint = (codepoint << 6U) | (next & 0x3FU);
        }
        if (codepoint < minimum || codepoint > 0x10FFFFU ||
            (codepoint >= 0xD800U && codepoint <= 0xDFFFU)) {
            return make_error(
                ErrorCode::invalid_argument,
                "idempotency key must contain valid Unicode scalars");
        }
        if (unicode_control(codepoint)) {
            return make_error(
                ErrorCode::invalid_argument,
                "idempotency key must not contain Unicode control characters");
        }
        has_non_whitespace =
            has_non_whitespace || !unicode_whitespace(codepoint);
        index += length;
    }
    if (!has_non_whitespace) {
        return make_error(
            ErrorCode::invalid_argument,
            "idempotency key must contain a non-whitespace Unicode scalar");
    }
    return {};
}

}  // namespace

std::string_view operation_name(Operation operation) noexcept {
    return info_for(operation).name;
}

OperationClass operation_class(Operation operation) noexcept {
    return info_for(operation).operation_class;
}


Result<MutationOptions> MutationOptions::with_key(std::string key) {
    auto validated = validate_idempotency_key(key);
    if (!validated) {
        return std::move(validated).error();
    }
    return MutationOptions(std::move(key));
}

MutationOptions MutationOptions::unique() {
    return MutationOptions(hex_128("cpp_", secure_random_128()));
}

Result<RunCommand> RunCommand::exact(std::vector<std::string> argv) {
    if (argv.empty() || argv.front().empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "argv must contain a non-empty executable");
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

Result<Json::Object> CreateWorkspaceOptions::to_params() const {
    Json::Object params{
        {
            "initial_content",
            Json(
                initial_content == InitialContent::terminal
                    ? "terminal"
                    : "empty"),
        },
    };
    if (name) {
        params.emplace("name", Json(*name));
    }
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
    }
    return params;
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
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
    }
    return params;
}

Result<Json::Object> CreateScreenOptions::to_params() const {
    Json::Object params;
    if (name) {
        params.emplace("name", Json(*name));
    }
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
    }
    return params;
}

Result<Json::Object> CreatePaneOptions::to_params() const {
    Json::Object params;
    if (cwd) {
        params.emplace("cwd", Json(*cwd));
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
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
    }
    return params;
}

Result<Json::Object> SplitPaneOptions::to_params() const {
    std::string_view direction_name;
    switch (direction) {
        case PaneDirection::left:
            direction_name = "left";
            break;
        case PaneDirection::right:
            direction_name = "right";
            break;
        case PaneDirection::up:
            direction_name = "up";
            break;
        case PaneDirection::down:
            direction_name = "down";
            break;
    }
    Json::Object params{
        {"direction", Json(std::string(direction_name))},
    };
    if (ratio) {
        if (!std::isfinite(*ratio) || *ratio <= 0.0 || *ratio >= 1.0) {
            return make_error(
                ErrorCode::invalid_argument,
                "split ratio must be finite and between zero and one");
        }
        params.emplace("ratio", Json(*ratio));
    }
    if (viewport_width) {
        if (direction != PaneDirection::right ||
            !std::isfinite(*viewport_width) || *viewport_width < 0.1 ||
            *viewport_width > 1.0) {
            return make_error(
                ErrorCode::invalid_argument,
                "viewport width requires a right split and a finite value "
                "between 0.1 and 1");
        }
        params.emplace("viewport_width", Json(*viewport_width));
    }
    if (cwd) {
        params.emplace("cwd", Json(*cwd));
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
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
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
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
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
    auto correlated = put_correlation_key(params, correlation_key);
    if (!correlated) {
        return std::move(correlated).error();
    }
    return params;
}

Result<Json::Object> UndoLayoutOptions::to_params() const {
    if (confirmation_token &&
        (confirmation_token->empty() || confirmation_token->size() > 128)) {
        return make_error(
            ErrorCode::invalid_argument,
            "confirmation_token must contain 1 to 128 UTF-8 bytes");
    }
    if (confirm_close && !confirmation_token) {
        return make_error(
            ErrorCode::invalid_argument,
            "confirmation_token is required when confirm_close is true");
    }
    Json::Object params;
    if (confirm_close) {
        params.emplace("confirm_close", Json(true));
    }
    if (confirmation_token) {
        params.emplace("confirmation_token", Json(*confirmation_token));
    }
    return params;
}

Result<Json::Object> TerminalHistoryOptions::to_params() const {
    if (limit && (*limit == 0 || *limit > 10'000)) {
        return make_error(
            ErrorCode::invalid_argument,
            "history limit must be between 1 and 10000");
    }
    Json::Object params;
    if (before) {
        params.emplace("before", Json(std::to_string(*before)));
    }
    if (limit) {
        params.emplace(
            "limit",
            Json(static_cast<std::uint64_t>(*limit)));
    }
    if (styled) {
        params.emplace("styled", Json(*styled));
    }
    return params;
}

Result<Json::Object> SessionJournalOptions::to_params() const {
    if (cursor && start) {
        return make_error(
            ErrorCode::invalid_argument,
            "journal cursor and start are mutually exclusive");
    }
    if (filter.max_sensitivity == JournalSensitivity::secret) {
        return make_error(
            ErrorCode::invalid_argument,
            "secret journal records are unavailable in v1");
    }
    Json::Object params;
    if (cursor) {
        params.emplace("cursor", cursor_json(*cursor));
    }
    if (start) {
        params.emplace(
            "start",
            Json(*start == JournalStart::tail ? "tail" : "beginning"));
    }
    if (follow) {
        params.emplace("follow", Json(*follow));
    }
    Json::Object encoded_filter;
    if (!filter.kinds.empty()) {
        Json::Array values;
        for (const auto& value : filter.kinds) values.emplace_back(value);
        encoded_filter.emplace("kinds", Json(std::move(values)));
    }
    if (!filter.classes.empty()) {
        Json::Array values;
        for (const auto value : filter.classes) {
            switch (value) {
                case JournalClass::state: values.emplace_back("state"); break;
                case JournalClass::observation: values.emplace_back("observation"); break;
                case JournalClass::effect: values.emplace_back("effect"); break;
                case JournalClass::checkpoint: values.emplace_back("checkpoint"); break;
            }
        }
        encoded_filter.emplace("classes", Json(std::move(values)));
    }
    if (!filter.subjects.empty()) {
        Json::Array values;
        for (const auto& subject : filter.subjects) {
            if (!subject.kind && !subject.id) {
                return make_error(
                    ErrorCode::invalid_argument,
                    "journal subject filters require kind or id");
            }
            Json::Object encoded;
            if (subject.kind) encoded.emplace("kind", Json(*subject.kind));
            if (subject.id) encoded.emplace("id", Json(*subject.id));
            values.emplace_back(std::move(encoded));
        }
        encoded_filter.emplace("subjects", Json(std::move(values)));
    }
    if (filter.max_sensitivity) {
        const char* value = "sensitive";
        if (*filter.max_sensitivity == JournalSensitivity::public_) value = "public";
        if (*filter.max_sensitivity == JournalSensitivity::metadata) value = "metadata";
        encoded_filter.emplace("max_sensitivity", Json(value));
    }
    if (filter.regex) {
        if (filter.regex->pattern.empty() || filter.regex->pattern.size() > 1024) {
            return make_error(
                ErrorCode::invalid_argument,
                "journal regex must contain 1 to 1024 UTF-8 bytes");
        }
        const char* field = nullptr;
        switch (filter.regex->field) {
            case JournalRegexField::kind: field = "kind"; break;
            case JournalRegexField::subjects: field = "subjects"; break;
            case JournalRegexField::payload: field = "payload"; break;
            case JournalRegexField::record: field = "record"; break;
            case JournalRegexField::terminal_output: field = "terminal_output"; break;
        }
        if (field == nullptr) {
            return make_error(
                ErrorCode::invalid_argument,
                "journal regex field is invalid");
        }
        encoded_filter.emplace(
            "regex",
            Json(Json::Object{
                {"pattern", Json(filter.regex->pattern)},
                {"field", Json(field)},
                {"case_sensitive", Json(filter.regex->case_sensitive)},
            }));
    }
    if (!encoded_filter.empty()) {
        params.emplace("filter", Json(std::move(encoded_filter)));
    }
    return params;
}

Result<Json::Object> TerminalAttachOptions::to_params() const {
    if (cols.has_value() != rows.has_value()) {
        return make_error(
            ErrorCode::invalid_argument,
            "cols and rows must be supplied together");
    }
    Json::Object params;
    if (cols) {
        if (*cols == 0 || *rows == 0) {
            return make_error(
                ErrorCode::invalid_argument,
                "cols and rows must be positive");
        }
        params.emplace("cols", Json(static_cast<std::uint64_t>(*cols)));
        params.emplace("rows", Json(static_cast<std::uint64_t>(*rows)));
    }
    if (read_only) {
        params.emplace("read_only", Json(true));
    }
    return params;
}

Result<Json::Object> NotificationCreateOptions::to_params() const {
    if (title.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "notification title must not be empty");
    }
    Json::Object params{
        {"title", Json(title)},
        {"body", Json(body)},
    };
    if (level) {
        std::string_view wire_level;
        switch (*level) {
            case NotificationLevel::info:
                wire_level = "info";
                break;
            case NotificationLevel::warning:
                wire_level = "warning";
                break;
            case NotificationLevel::error:
                wire_level = "error";
                break;
        }
        params.emplace("level", Json(std::string(wire_level)));
    }
    if (terminal_id) {
        if (terminal_id->empty()) {
            return make_error(
                ErrorCode::invalid_argument,
                "notification terminal ID must not be empty");
        }
        params.emplace("terminal_id", Json(terminal_id->value()));
    }
    return params;
}

Result<Json::Object> AgentReportOptions::to_params() const {
    if (terminal_id.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "agent terminal ID must not be empty");
    }
    std::string_view wire_state;
    switch (state) {
        case AgentState::working:
            wire_state = "working";
            break;
        case AgentState::blocked:
            wire_state = "blocked";
            break;
        case AgentState::idle:
            wire_state = "idle";
            break;
        case AgentState::done:
            wire_state = "done";
            break;
        case AgentState::unknown:
            wire_state = "unknown";
            break;
    }
    const std::string_view wire_source =
        source == AgentReportSource::hook ? "hook" : "socket";
    Json::Object params{
        {"terminal_id", Json(terminal_id.value())},
        {"state", Json(std::string(wire_state))},
        {"source", Json(std::string(wire_source))},
    };
    if (source_session) {
        params.emplace("source_session", Json(*source_session));
    }
    return params;
}

namespace detail {

void complete_structural_route(
    Json::Object& route,
    std::string_view target_scope) {
    constexpr std::array<std::string_view, 4> structural_ancestors{
        "workspace",
        "screen",
        "pane",
        "tab",
    };
    std::size_t required = 0;
    if (target_scope == "screen") {
        required = 1;
    } else if (target_scope == "pane") {
        required = 2;
    } else if (target_scope == "tab") {
        required = 3;
    } else if (target_scope == "terminal" || target_scope == "browser") {
        required = 4;
    }
    for (std::size_t index = 0; index < required; ++index) {
        route.try_emplace(
            std::string(structural_ancestors[index]),
            Json("current"));
    }
}

class ResourceClientState
    : public std::enable_shared_from_this<ResourceClientState> {
public:
    ClientOptions options;
    std::unique_ptr<Transport> control;
    TransportFactory stream_factory;
    std::timed_mutex request_mutex;
    std::atomic<std::uint64_t> next_request_id{1};
    std::atomic<bool> is_closed{false};

    [[nodiscard]] Result<void> cancel_abandoned_request(
        std::string_view target_request_id,
        Operation target_operation) {
        const auto deadline =
            std::chrono::steady_clock::now() + options.timeout;
        const auto remaining = [&]() -> Timeout {
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                return Timeout::zero();
            }
            return std::max(
                Timeout(1),
                std::chrono::duration_cast<Timeout>(deadline - now));
        };
        const auto cancel_request_id =
            "cpp-request-" +
            std::to_string(
                next_request_id.fetch_add(1, std::memory_order_relaxed));
        auto timeout = remaining();
        if (timeout == Timeout::zero()) {
            return make_error(
                ErrorCode::timeout,
                "request cleanup timed out before cancellation");
        }
        auto sent = send_envelope(
            *control,
            cancel_request_id,
            Operation::request_cancel,
            {
                {
                    "request_id",
                    Json(std::string(target_request_id)),
                },
            },
            std::nullopt,
            timeout,
            options.json_limits);
        if (!sent) {
            return std::move(sent).error();
        }

        std::optional<bool> cancel_result;
        bool target_seen = false;
        while (true) {
            timeout = remaining();
            if (timeout == Timeout::zero()) {
                return make_error(
                    ErrorCode::timeout,
                    "request cleanup timed out");
            }
            auto wire = control->receive(timeout);
            if (!wire) {
                return std::move(wire).error();
            }
            auto parsed = Json::parse(wire.value(), options.json_limits);
            if (!parsed) {
                return std::move(parsed).error();
            }
            auto protocol = require_string(parsed.value(), "protocol");
            auto type = require_string(parsed.value(), "type");
            auto response_id = require_string(parsed.value(), "id");
            if (!protocol || protocol.value() != "cmux.protocol/2" ||
                !type || type.value() != "response" || !response_id) {
                return make_error(
                    ErrorCode::protocol,
                    "request cleanup requires a cmux.protocol/2 response");
            }
            if (response_id.value() == target_request_id) {
                if (target_seen) {
                    return make_error(
                        ErrorCode::protocol,
                        "request cleanup received duplicate target response");
                }
                auto completed = decode_response(
                    parsed.value(),
                    target_request_id,
                    "abandoned request response");
                if (!completed) {
                    auto error = std::move(completed).error();
                    if (error.code != ErrorCode::command) {
                        return error;
                    }
                } else if (target_operation == Operation::terminal_wait) {
                    auto typed = detail::decode_value<TerminalWaitResult>(
                        completed.value());
                    if (!typed) {
                        return std::move(typed).error();
                    }
                } else if (
                    target_operation == Operation::terminal_wait_exit) {
                    auto typed =
                        detail::decode_value<TerminalWaitExitResult>(
                            completed.value());
                    if (!typed) {
                        return std::move(typed).error();
                    }
                }
                target_seen = true;
            } else if (response_id.value() == cancel_request_id) {
                if (cancel_result) {
                    return make_error(
                        ErrorCode::protocol,
                        "request cleanup received duplicate cancel response");
                }
                auto response = decode_response(
                    parsed.value(),
                    cancel_request_id,
                    "request cancel response");
                if (!response) {
                    return std::move(response).error();
                }
                auto exact = require_exact_fields(
                    response.value(),
                    {"canceled"},
                    "request cancel result");
                auto canceled =
                    require_bool(response.value(), "canceled");
                if (!exact || !canceled) {
                    return make_error(
                        ErrorCode::protocol,
                        "request cancel result must contain only boolean "
                        "canceled");
                }
                cancel_result = canceled.value();
            } else {
                return make_error(
                    ErrorCode::protocol,
                    "request cleanup received an unknown response ID");
            }

            if (cancel_result == true) {
                if (target_seen) {
                    return make_error(
                        ErrorCode::protocol,
                        "canceled request also emitted a target response");
                }
                return {};
            }
            if (cancel_result == false && target_seen) {
                return {};
            }
        }
    }

    [[nodiscard]] Result<Json> call(
        Operation operation,
        Json::Object params,
        std::optional<std::string> idempotency_key,
        CallOptions call) {
        const auto deadline = call.deadline.value_or(
            std::chrono::steady_clock::now() + options.timeout);
        const auto remaining = [&]() -> Timeout {
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                return Timeout::zero();
            }
            return std::max(
                Timeout(1),
                std::chrono::duration_cast<Timeout>(deadline - now));
        };
        std::unique_lock<std::timed_mutex> lock(
            request_mutex,
            std::defer_lock);
        while (!lock.owns_lock()) {
            if (call.cancel.stop_requested()) {
                return make_error(
                    ErrorCode::canceled,
                    "operation was canceled before request admission");
            }
            auto timeout = remaining();
            if (timeout == Timeout::zero()) {
                return make_error(
                    ErrorCode::timeout,
                    "operation timed out before request admission");
            }
            if (call.cancel.stop_possible()) {
                timeout = std::min(timeout, Timeout(25));
                (void)lock.try_lock_for(timeout);
            } else {
#if defined(CMUX_CPP_TESTING)
                if (!detail::consume_simulated_request_lock_failure()) {
#endif
                    (void)lock.try_lock_until(deadline);
#if defined(CMUX_CPP_TESTING)
                }
#endif
            }
        }
        if (is_closed.load(std::memory_order_acquire)) {
            return make_error(ErrorCode::closed, "client is closed");
        }
        if (call.cancel.stop_requested()) {
            return make_error(
                ErrorCode::canceled,
                "operation was canceled before send");
        }
        if (remaining() == Timeout::zero()) {
            return make_error(
                ErrorCode::timeout,
                "operation timed out before send");
        }
        const auto mutation_key = idempotency_key;
        const auto outcome_error = [&](Error error) {
            if (mutation_key && error.code != ErrorCode::command &&
                error.code != ErrorCode::invalid_argument) {
                error.code = ErrorCode::outcome_uncertain;
                error.retryable = false;
                error.uncertain_mutation =
                    std::make_shared<MutationOutcomeUncertain>(
                        MutationOutcomeUncertain{operation, *mutation_key});
            }
            return error;
        };
        const auto request_id =
            "cpp-request-" +
            std::to_string(
                next_request_id.fetch_add(1, std::memory_order_relaxed));
        inject_routing(options, operation, params);
        const auto send_timeout = remaining();
        if (send_timeout == Timeout::zero()) {
            return make_error(
                ErrorCode::timeout,
                "operation timed out before send");
        }
        auto sent = send_envelope(
            *control,
            request_id,
            operation,
            std::move(params),
            std::move(idempotency_key),
            send_timeout,
            options.json_limits);
        if (!sent) {
            close();
            return outcome_error(std::move(sent).error());
        }
        const auto finish_abandoned =
            [&](Error original) -> Result<Json> {
            const bool cancellable =
                operation == Operation::terminal_wait ||
                operation == Operation::terminal_wait_exit;
            if (cancellable &&
                (original.code == ErrorCode::timeout ||
                 original.code == ErrorCode::canceled)) {
                auto cleaned =
                    cancel_abandoned_request(request_id, operation);
                if (!cleaned) {
                    close();
                }
            }
            return outcome_error(std::move(original));
        };
        while (true) {
            if (call.cancel.stop_requested()) {
                return finish_abandoned(
                    make_error(ErrorCode::canceled, "operation was canceled"));
            }
            auto timeout = remaining();
            if (timeout == Timeout::zero()) {
                return finish_abandoned(
                    make_error(ErrorCode::timeout, "operation timed out"));
            }
            if (call.cancel.stop_possible()) {
                timeout = std::min(timeout, Timeout(25));
            }
            auto wire = control->receive(timeout);
            if (!wire) {
                if (wire.error().code == ErrorCode::timeout &&
                    call.cancel.stop_possible() &&
                    remaining() != Timeout::zero()) {
                    continue;
                }
                return finish_abandoned(std::move(wire).error());
            }
            auto parsed = Json::parse(wire.value(), options.json_limits);
            if (!parsed) {
                return outcome_error(std::move(parsed).error());
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
            auto decoded = decode_response(parsed.value(), request_id);
            if (!decoded) {
                return outcome_error(std::move(decoded).error());
            }
            return decoded;
        }
    }

    [[nodiscard]] Result<std::unique_ptr<ResourceStream::Impl>> open_stream(
        Operation operation,
        Json::Object params,
        CallOptions call);

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
            {"protocol", Json("cmux.protocol/2")},
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
    Json::Object params,
    CallOptions call) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::read) {
        return wrong_class(operation, OperationClass::read);
    }
    return state->call(
        operation, std::move(params), std::nullopt, std::move(call));
}

Result<Json> resource_control(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    CallOptions call) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::connection_control) {
        return wrong_class(operation, OperationClass::connection_control);
    }
    return state->call(
        operation, std::move(params), std::nullopt, std::move(call));
}

Result<RawMutationResult> resource_mutate(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    MutationOptions options,
    CallOptions call) {
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
        expected_key,
        std::move(call));
    if (!result) {
        auto error = std::move(result).error();
        if (error.protocol_code == "mutation.indeterminate") {
            error.code = ErrorCode::outcome_uncertain;
            error.retryable = false;
            error.uncertain_mutation =
                std::make_shared<MutationOutcomeUncertain>(
                    MutationOutcomeUncertain{
                        operation,
                        expected_key,
                    });
        }
        return error;
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
    if (!options.transport_factory) {
        auto path = resolve_socket_path(
            options.socket_path, options.session);
        if (!path) {
            return std::move(path).error();
        }
        auto resolved_path = std::move(path).value();
        const bool implicit = options.socket_path.empty() && socket_path_from_environment().empty();
        std::string legacy;
        if (implicit && ::cmux::detail::is_hashed_socket_path_for_uid(
                resolved_path, static_cast<unsigned long>(::getuid()))) {
            legacy = "/tmp/cmux-tui-" + std::to_string(static_cast<unsigned long>(::getuid())) + "/" + options.session + ".sock";
            if (legacy.size() >= sizeof(sockaddr_un{}.sun_path)) legacy.clear();
        }
        auto effective = std::make_shared<std::string>(resolved_path);
        options.transport_factory = [effective, legacy, timeout = options.timeout, limits = options.transport_limits]() mutable {
            auto first = UnixTransport::connect(*effective, timeout, limits);
            if (first || legacy.empty() || (first.error().system_errno != ENOENT && first.error().system_errno != ECONNREFUSED)) return first;
            auto fallback = UnixTransport::connect(legacy, timeout, limits);
            if (fallback) *effective = legacy;
            return fallback;
        };
        options.socket_path = resolved_path;
        if (!legacy.empty()) options.stream_transport_factory = [effective, timeout = options.timeout, limits = options.transport_limits]() { return UnixTransport::connect(*effective, timeout, limits); };
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
    Json::Object params,
    CallOptions call) const {
    return detail::resource_read(
        state_, operation, std::move(params), std::move(call));
}

Result<RawMutationResult> Client::mutate(
    Operation operation,
    Json::Object params,
    MutationOptions options,
    CallOptions call) const {
    return detail::resource_mutate(
        state_,
        operation,
        std::move(params),
        std::move(options),
        std::move(call));
}

Result<Json> Client::connection_control(
    Operation operation,
    Json::Object params,
    CallOptions call) const {
    return detail::resource_control(
        state_, operation, std::move(params), std::move(call));
}

Result<ResourceStream> Client::open_stream(
    Operation operation,
    Json::Object params,
    CallOptions call) const {
    return detail::resource_open_stream(
        state_, operation, std::move(params), std::move(call));
}

Result<SessionEventStream> Client::open_session_events(
    Json::Object params,
    CallOptions call) const {
    auto stream = open_stream(
        Operation::session_events, std::move(params), std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionEventStream(std::move(stream).value());
}

Result<SessionJournalStream> Client::open_session_journal(
    Json::Object params,
    CallOptions call) const {
    auto stream = open_stream(
        Operation::session_journal_subscribe,
        std::move(params),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionJournalStream(std::move(stream).value());
}

Result<TerminalAttachmentStream> Client::open_terminal_attachment(
    Json::Object params,
    CallOptions call) const {
    auto stream = open_stream(
        Operation::terminal_attach, std::move(params), std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return TerminalAttachmentStream(std::move(stream).value());
}

Result<BrowserAttachmentStream> Client::open_browser_attachment(
    Json::Object params,
    CallOptions call) const {
    auto stream = open_stream(
        Operation::browser_attach, std::move(params), std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return BrowserAttachmentStream(std::move(stream).value());
}

Result<SidebarViewStream> Client::open_sidebar_view(
    Json::Object params,
    CallOptions call) const {
    auto stream = open_stream(
        Operation::sidebar_view_attach, std::move(params), std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SidebarViewStream(std::move(stream).value());
}

Machine Client::machine(Selector<MachineId> selector) const {
    return Machine(state_, std::move(selector), "machine");
}

Machine Client::machine(MachineId id) const {
    return machine(Selector<MachineId>::by_id(std::move(id)));
}

Session Client::session(Selector<SessionId> selector) const {
    return Session(state_, std::move(selector), "session");
}

Session Client::session(SessionId id) const {
    return session(Selector<SessionId>::by_id(std::move(id)));
}

Workspace Client::workspace(Selector<WorkspaceId> selector) const {
    return Workspace(state_, std::move(selector), "workspace");
}

Workspace Client::workspace(WorkspaceId id) const {
    return workspace(Selector<WorkspaceId>::by_id(std::move(id)));
}

Screen Client::screen(Selector<ScreenId> selector) const {
    return Screen(state_, std::move(selector), "screen");
}

Screen Client::screen(ScreenId id) const {
    return screen(Selector<ScreenId>::by_id(std::move(id)));
}

Pane Client::pane(Selector<PaneId> selector) const {
    return Pane(state_, std::move(selector), "pane");
}

Pane Client::pane(PaneId id) const {
    return pane(Selector<PaneId>::by_id(std::move(id)));
}

Tab Client::tab(Selector<TabId> selector) const {
    return Tab(state_, std::move(selector), "tab");
}

Tab Client::tab(TabId id) const {
    return tab(Selector<TabId>::by_id(std::move(id)));
}

Terminal Client::terminal(Selector<TerminalId> selector) const {
    return Terminal(state_, std::move(selector), "terminal");
}

Terminal Client::terminal(TerminalId id) const {
    return terminal(Selector<TerminalId>::by_id(std::move(id)));
}

Browser Client::browser(Selector<BrowserId> selector) const {
    return Browser(state_, std::move(selector), "browser");
}

Browser Client::browser(BrowserId id) const {
    return browser(Selector<BrowserId>::by_id(std::move(id)));
}

ConnectedClient Client::connected_client(
    Selector<ConnectedClientId> selector) const {
    return ConnectedClient(state_, std::move(selector), "client");
}

ConnectedClient Client::connected_client(ConnectedClientId id) const {
    return connected_client(
        Selector<ConnectedClientId>::by_id(std::move(id)));
}

Notification Client::notification(
    Selector<NotificationId> selector) const {
    return Notification(state_, std::move(selector), "notification");
}

Notification Client::notification(NotificationId id) const {
    return notification(Selector<NotificationId>::by_id(std::move(id)));
}

Agent Client::agent(Selector<AgentId> selector) const {
    return Agent(state_, std::move(selector), "agent");
}

Agent Client::agent(AgentId id) const {
    return agent(Selector<AgentId>::by_id(std::move(id)));
}

PairingRequest Client::pairing_request(
    Selector<PairingRequestId> selector) const {
    return PairingRequest(state_, std::move(selector), "pairing_request");
}

PairingRequest Client::pairing_request(PairingRequestId id) const {
    return pairing_request(
        Selector<PairingRequestId>::by_id(std::move(id)));
}

FrontendProjection Client::projection(
    Selector<FrontendProjectionId> selector) const {
    return FrontendProjection(
        state_, std::move(selector), "frontend_projection");
}

FrontendProjection Client::projection(FrontendProjectionId id) const {
    return projection(
        Selector<FrontendProjectionId>::by_id(std::move(id)));
}

Result<FrontendProjectionSnapshot> FrontendProjection::refresh() const {
    return read(Operation::frontend_projection_get);
}

Result<MutationResult<FrontendProjectionSnapshot>> FrontendProjection::put(
    ProjectionPutOptions projection,
    MutationOptions options) const {
    if (projection.frontend_id.empty() || projection.frontend_id.size() > 128 ||
        projection.window_id.empty() || projection.window_id.size() > 128 ||
        projection.generation.empty() || projection.generation.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "frontend, window, and generation IDs must contain 1 to 128 bytes");
    }
    Json::Object params{
        {"frontend_id", Json(std::move(projection.frontend_id))},
        {"window_id", Json(std::move(projection.window_id))},
        {"generation", Json(std::move(projection.generation))},
        {"projection", std::move(projection.projection)},
    };
    if (projection.expected_projection_revision) {
        params.emplace(
            "expected_projection_revision",
            Json(std::to_string(*projection.expected_projection_revision)));
    }
    return mutate(
        Operation::frontend_projection_put,
        std::move(params),
        std::move(options));
}

SidebarView Client::sidebar_view(
    Selector<SidebarViewId> selector) const {
    return SidebarView(state_, std::move(selector), "sidebar_view");
}

SidebarView Client::sidebar_view(SidebarViewId id) const {
    return sidebar_view(Selector<SidebarViewId>::by_id(std::move(id)));
}

Result<std::vector<MachineSnapshot>> Client::machines() const {
    return detail::ResourceReadResult(read(Operation::machine_list));
}

Result<std::vector<SessionSnapshot>> Client::sessions(
    std::optional<Selector<MachineId>> machine_selector) const {
    Json::Object params;
    if (machine_selector) {
        params.emplace("machine", Json(machine_selector->wire()));
    }
    return detail::ResourceReadResult(
        read(Operation::session_list, std::move(params)));
}

Result<MutationResult<SessionSnapshot>> Client::open_session(
    Json::Object params,
    MutationOptions options) const {
    return detail::ResourceMutationResult(mutate(
        Operation::session_open, std::move(params), std::move(options)));
}

Result<std::vector<AgentSnapshot>> Client::agents(Json::Object params) const {
    return detail::ResourceReadResult(
        read(Operation::agent_list, std::move(params)));
}

Result<std::vector<PairingRequestSnapshot>> Client::pairing_requests(Json::Object params) const {
    return detail::ResourceReadResult(
        read(Operation::pairing_request_list, std::move(params)));
}

Result<MachineSnapshot> Machine::refresh() const {
    return read(Operation::machine_get);
}

Result<std::vector<SessionSnapshot>> Machine::sessions() const {
    return read(Operation::session_list);
}

Session Machine::session(Selector<SessionId> selector) const {
    return Session(state_, std::move(selector), "session", route_);
}

Session Machine::session(SessionId id) const {
    return session(Selector<SessionId>::by_id(std::move(id)));
}

Result<SessionSnapshot> Session::refresh() const {
    return read(Operation::session_get);
}

Result<ResourceSnapshot> Session::snapshot() const {
    return read(Operation::session_snapshot);
}

Result<PingResult> Session::ping() const {
    return read(Operation::session_ping);
}

Result<CreationResolution> Session::resolve_creation(
    std::string correlation_key) const {
    if (correlation_key.empty() || correlation_key.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "correlation key must contain 1 to 128 UTF-8 bytes");
    }
    return read(
        Operation::session_creation_resolve,
        Json::Object{
            {"correlation_key", Json(std::move(correlation_key))},
        });
}

Result<std::vector<WorkspaceSnapshot>> Session::workspaces() const {
    return read(Operation::workspace_list);
}

Result<std::vector<NotificationSnapshot>> Session::notifications(
    std::optional<std::uint32_t> limit) const {
    Json::Object params;
    if (limit) {
        if (*limit == 0 || *limit > 1'000) {
            return make_error(
                ErrorCode::invalid_argument,
                "notification limit must be between 1 and 1000");
        }
        params.emplace("limit", Json(static_cast<std::uint64_t>(*limit)));
    }
    return read(Operation::notification_list, std::move(params));
}

Result<MutationResult<NotificationSnapshot>> Session::create_notification(
    NotificationCreateOptions create,
    MutationOptions mutation) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::notification_create,
        std::move(params).value(),
        std::move(mutation));
}

Result<MutationResult<AgentSnapshot>> Session::report_agent(
    AgentReportOptions report,
    MutationOptions mutation) const {
    auto params = report.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::agent_report,
        std::move(params).value(),
        std::move(mutation));
}

Workspace Session::workspace(Selector<WorkspaceId> selector) const {
    return Workspace(state_, std::move(selector), "workspace", route_);
}

Workspace Session::workspace(WorkspaceId id) const {
    return workspace(Selector<WorkspaceId>::by_id(std::move(id)));
}

Result<MutationResult<CreatedPath>> Session::create_workspace(
    CreateWorkspaceOptions create,
    MutationOptions mutation) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::workspace_create,
        std::move(params).value(),
        std::move(mutation));
}

Result<SessionEventStream> Session::events(
    std::optional<Cursor> cursor,
    CallOptions call) const {
    Json::Object params = routed_params();
    if (cursor) {
        params.emplace("cursor", cursor_json(*cursor));
    }
    auto stream = detail::resource_open_stream(
        state_,
        Operation::session_events,
        std::move(params),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionEventStream(std::move(stream).value());
}

Result<SessionJournalStream> Session::journal(
    SessionJournalOptions options,
    CallOptions call) const {
    auto encoded = options.to_params();
    if (!encoded) {
        return std::move(encoded).error();
    }
    auto params = routed_params();
    params.merge(std::move(encoded).value());
    auto stream = detail::resource_open_stream(
        state_,
        Operation::session_journal_subscribe,
        std::move(params),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SessionJournalStream(std::move(stream).value());
}

Result<MutationResult<ShutdownResult>> Session::shutdown(MutationOptions options) const {
    return mutate(Operation::session_shutdown, {}, std::move(options));
}

Result<MutationResult<ReloadConfigResult>> Session::reload_config(MutationOptions options) const {
    return mutate(Operation::session_reload_config, {}, std::move(options));
}

Result<MutationResult<TerminalDefaultsSnapshot>> Session::update_terminal_defaults(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::session_terminal_defaults_update,
        std::move(params),
        std::move(options));
}

Result<MutationResult<EmptyResult>> Session::set_window_title(
    std::string title,
    MutationOptions options) const {
    return mutate(
        Operation::session_window_title_set,
        Json::Object{{"title", Json(std::move(title))}},
        std::move(options));
}

Result<MutationResult<EmptyResult>> Session::clear_window_title(
    MutationOptions options) const {
    return mutate(
        Operation::session_window_title_clear, {}, std::move(options));
}

Result<WorkspaceSnapshot> Workspace::refresh() const {
    return read(Operation::workspace_get);
}

Result<std::vector<ScreenSnapshot>> Workspace::screens() const {
    return read(Operation::screen_list);
}

Screen Workspace::screen(Selector<ScreenId> selector) const {
    return Screen(state_, std::move(selector), "screen", route_);
}

Screen Workspace::screen(ScreenId id) const {
    return screen(Selector<ScreenId>::by_id(std::move(id)));
}

Result<MutationResult<CreatedTerminalPath>> Workspace::create_screen(
    CreateScreenOptions create,
    MutationOptions options) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::screen_create,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult<WorkspaceSnapshot>> Workspace::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult<WorkspaceSnapshot>> Workspace::clear_name(
    MutationOptions options) const {
    // Workspace names are required strings. Empty explicitly clears the label.
    return rename("", std::move(options));
}

Result<MutationResult<WorkspaceSnapshot>> Workspace::move(
    std::size_t index,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_move,
        Json::Object{{"index", Json(static_cast<std::uint64_t>(index))}},
        std::move(options));
}

Result<MutationResult<WorkspaceSnapshot>> Workspace::focus(MutationOptions options) const {
    return mutate(Operation::workspace_focus, {}, std::move(options));
}

Result<MutationResult<EmptyResult>> Workspace::close(MutationOptions options) const {
    return mutate(Operation::workspace_close, {}, std::move(options));
}

Result<MutationResult<CreatedTerminalPath>> Workspace::run(
    RunOptions run,
    MutationOptions options,
    CallOptions call) const {
    auto params = run.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::workspace_run,
        std::move(params).value(),
        std::move(options),
        std::move(call));
}

Result<MutationResult<WorkspaceSnapshot>> Workspace::apply_layout(
    Json document,
    MutationOptions options) const {
    return mutate(
        Operation::workspace_layout_apply,
        Json::Object{{"layout", std::move(document)}},
        std::move(options));
}

Result<ScreenSnapshot> Screen::refresh() const {
    return read(Operation::screen_get);
}

Result<std::vector<PaneSnapshot>> Screen::panes() const {
    return read(Operation::pane_list);
}

Pane Screen::pane(Selector<PaneId> selector) const {
    return Pane(state_, std::move(selector), "pane", route_);
}

Pane Screen::pane(PaneId id) const {
    return pane(Selector<PaneId>::by_id(std::move(id)));
}

Result<MutationResult<CreatedTerminalPath>> Screen::create_pane(
    CreatePaneOptions create,
    MutationOptions options) const {
    auto params = create.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::pane_create,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult<ScreenSnapshot>> Screen::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::screen_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult<ScreenSnapshot>> Screen::clear_name(MutationOptions options) const {
    return mutate(
        Operation::screen_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult<ScreenSnapshot>> Screen::focus(MutationOptions options) const {
    return mutate(Operation::screen_focus, {}, std::move(options));
}

Result<MutationResult<EmptyResult>> Screen::close(MutationOptions options) const {
    return mutate(Operation::screen_close, {}, std::move(options));
}

Result<LayoutDocument> Screen::export_layout() const {
    return read(Operation::screen_layout_export);
}

Result<MutationResult<ScreenSnapshot>> Screen::undo_layout(
    UndoLayoutOptions undo,
    MutationOptions options) const {
    auto params = undo.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::screen_layout_undo,
        std::move(params).value(),
        std::move(options));
}

Result<PaneSnapshot> Pane::refresh() const {
    return read(Operation::pane_get);
}

Result<std::vector<TabSnapshot>> Pane::tabs() const {
    return read(Operation::tab_list);
}

Tab Pane::tab(Selector<TabId> selector) const {
    return Tab(state_, std::move(selector), "tab", route_);
}

Tab Pane::tab(TabId id) const {
    return tab(Selector<TabId>::by_id(std::move(id)));
}

Result<MutationResult<CreatedTerminalPath>> Pane::split(
    SplitPaneOptions split,
    MutationOptions options) const {
    auto params = split.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return mutate(
        Operation::pane_split,
        std::move(params).value(),
        std::move(options));
}

Result<MutationResult<PaneSnapshot>> Pane::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::pane_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult<PaneSnapshot>> Pane::clear_name(MutationOptions options) const {
    return mutate(
        Operation::pane_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult<PaneSnapshot>> Pane::focus(MutationOptions options) const {
    return mutate(Operation::pane_focus, {}, std::move(options));
}

Result<MutationResult<PaneSnapshot>> Pane::focus_direction(
    std::string direction,
    MutationOptions options) const {
    return mutate(
        Operation::pane_focus_direction,
        Json::Object{{"direction", Json(std::move(direction))}},
        std::move(options));
}

Result<PaneNeighborResult> Pane::neighbor(std::string direction) const {
    return read(
        Operation::pane_neighbor_get,
        Json::Object{{"direction", Json(std::move(direction))}});
}

Result<MutationResult<PaneSnapshot>> Pane::swap(
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

Result<MutationResult<PaneSnapshot>> Pane::zoom(
    std::optional<bool> zoomed,
    MutationOptions options) const {
    Json::Object params;
    if (zoomed) {
        params.emplace("enabled", Json(*zoomed));
    }
    return mutate(Operation::pane_zoom, std::move(params), std::move(options));
}

Result<MutationResult<PaneSnapshot>> Pane::set_split_ratio(
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

Result<MutationResult<PaneSnapshot>> Pane::set_viewport_width(
    std::uint16_t columns,
    MutationOptions options) const {
    return mutate(
        Operation::pane_viewport_width_set,
        Json::Object{{"columns", Json(static_cast<std::uint64_t>(columns))}},
        std::move(options));
}

Result<MutationResult<EmptyResult>> Pane::close(MutationOptions options) const {
    return mutate(Operation::pane_close, {}, std::move(options));
}

Result<MutationResult<CreatedTerminalPath>> Pane::run(
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

Result<MutationResult<CreatedTerminalPath>> Pane::create_terminal_tab(
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

Result<MutationResult<CreatedBrowserPath>> Pane::create_browser_tab(
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

Result<TabSnapshot> Tab::refresh() const {
    return read(Operation::tab_get);
}

Terminal Tab::terminal(Selector<TerminalId> selector) const {
    return Terminal(state_, std::move(selector), "terminal", route_);
}

Terminal Tab::terminal(TerminalId id) const {
    return terminal(Selector<TerminalId>::by_id(std::move(id)));
}

Browser Tab::browser(Selector<BrowserId> selector) const {
    return Browser(state_, std::move(selector), "browser", route_);
}

Browser Tab::browser(BrowserId id) const {
    return browser(Selector<BrowserId>::by_id(std::move(id)));
}

Result<MutationResult<TabSnapshot>> Tab::rename(
    std::string name,
    MutationOptions options) const {
    return mutate(
        Operation::tab_rename,
        Json::Object{{"name", Json(std::move(name))}},
        std::move(options));
}

Result<MutationResult<TabSnapshot>> Tab::clear_name(MutationOptions options) const {
    return mutate(
        Operation::tab_rename,
        Json::Object{{"name", Json(nullptr)}},
        std::move(options));
}

Result<MutationResult<TabSnapshot>> Tab::move(
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

Result<MutationResult<TabSnapshot>> Tab::focus(MutationOptions options) const {
    return mutate(Operation::tab_focus, {}, std::move(options));
}

Result<MutationResult<EmptyResult>> Tab::close(MutationOptions options) const {
    return mutate(Operation::tab_close, {}, std::move(options));
}

Result<TerminalSnapshot> Terminal::refresh() const {
    return read(Operation::terminal_get);
}

Result<MutationResult<EmptyResult>> Terminal::write(
    std::string text,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_write,
        Json::Object{{"text", Json(std::move(text))}},
        std::move(options));
}

Result<MutationResult<EmptyResult>> Terminal::keys(
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

Result<MutationResult<EmptyResult>> Terminal::mouse(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_mouse,
        std::move(params),
        std::move(options));
}

Result<MutationResult<EmptyResult>> Terminal::input_focus(
    bool focused,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_input_focus,
        Json::Object{{"focused", Json(focused)}},
        std::move(options));
}

Result<TerminalScreenResult> Terminal::read_screen(Json::Object params) const {
    return read(Operation::terminal_screen_read, std::move(params));
}

Result<TerminalStateResult> Terminal::read_state() const {
    return read(Operation::terminal_state_read);
}

Result<TerminalHistoryResult> Terminal::read_history(
    TerminalHistoryOptions options) const {
    auto params = options.to_params();
    if (!params) {
        return std::move(params).error();
    }
    return read(
        Operation::terminal_history_read,
        std::move(params).value());
}

Result<MutationResult<EmptyResult>> Terminal::clear_history(
    MutationOptions options) const {
    return mutate(
        Operation::terminal_history_clear, {}, std::move(options));
}

Result<TerminalWaitResult> Terminal::wait(
    std::string pattern,
    std::optional<std::uint64_t> timeout_ms,
    CallOptions call) const {
    if (pattern.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "terminal wait pattern must not be empty");
    }
    Json::Object params{{"pattern", Json(std::move(pattern))}};
    if (timeout_ms) {
        params.emplace("timeout_ms", Json(std::to_string(*timeout_ms)));
    }
    return read(
        Operation::terminal_wait,
        std::move(params),
        std::move(call));
}

Result<TerminalWaitExitResult> Terminal::wait_exit(
    std::optional<std::uint64_t> timeout_ms,
    CallOptions call) const {
    Json::Object params;
    if (timeout_ms) {
        params.emplace("timeout_ms", Json(std::to_string(*timeout_ms)));
    }
    return read(
        Operation::terminal_wait_exit,
        std::move(params),
        std::move(call));
}

Result<TerminalCopyResult> Terminal::copy(Json::Object params) const {
    return read(Operation::terminal_copy, std::move(params));
}

Result<ProcessInfoResult> Terminal::process() const {
    return read(Operation::terminal_process_get);
}

Result<RendererGrant> Terminal::renderer_grant(Json::Object params) const {
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::terminal_renderer_grant_create,
        routed_params(std::move(params)),
        {}));
}

Result<ViewerResizeResult> Terminal::resize_viewer(
    std::string attachment_lease,
    std::uint16_t columns,
    std::uint16_t rows) const {
    if (columns == 0 || rows == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "terminal cell dimensions must be positive");
    }
    if (attachment_lease.empty() || attachment_lease.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "attachment lease must contain 1 to 128 bytes");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::terminal_viewer_resize,
        routed_params(Json::Object{
            {"attachment_lease", Json(std::move(attachment_lease))},
            {"cols", Json(static_cast<std::uint64_t>(columns))},
            {"rows", Json(static_cast<std::uint64_t>(rows))},
        }),
        {}));
}

Result<ViewerReleaseResult> Terminal::release_viewer(
    std::string attachment_lease) const {
    if (attachment_lease.empty() || attachment_lease.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "attachment lease must contain 1 to 128 bytes");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::terminal_viewer_release,
        routed_params(Json::Object{
            {"attachment_lease", Json(std::move(attachment_lease))},
        }),
        {}));
}

Result<MutationResult<EmptyResult>> Terminal::scroll(
    std::int32_t delta_rows,
    MutationOptions options) const {
    return mutate(
        Operation::terminal_viewport_scroll,
        Json::Object{{"delta_rows", Json(static_cast<std::int64_t>(delta_rows))}},
        std::move(options));
}

Result<MutationResult<TerminalSnapshot>> Terminal::move(
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

Result<MutationResult<TabSnapshot>> Terminal::project(
    PaneDestination destination,
    std::optional<std::string> name,
    MutationOptions options) const {
    Json::Object params{
        {"destination_workspace", Json(destination.workspace.wire())},
        {"destination_screen", Json(destination.screen.wire())},
        {"destination_pane", Json(destination.pane.wire())},
        {"index", Json(static_cast<std::uint64_t>(destination.index))},
    };
    if (name.has_value()) {
        params.emplace("name", Json(std::move(name).value()));
    }
    return mutate(
        Operation::terminal_project,
        std::move(params),
        std::move(options));
}

Result<TerminalAttachmentStream> Terminal::attach(
    TerminalAttachOptions options,
    CallOptions call) const {
    auto params = options.to_params();
    if (!params) {
        return std::move(params).error();
    }
    auto stream = detail::resource_open_stream(
        state_,
        Operation::terminal_attach,
        routed_params(std::move(params).value()),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return TerminalAttachmentStream(std::move(stream).value());
}

Result<MutationResult<EmptyResult>> Terminal::close(MutationOptions options) const {
    return mutate(Operation::terminal_close, {}, std::move(options));
}

Result<BrowserSnapshot> Browser::refresh() const {
    return read(Operation::browser_get);
}

Result<MutationResult<BrowserSnapshot>> Browser::navigate(
    std::string url,
    MutationOptions options) const {
    return mutate(
        Operation::browser_navigate,
        Json::Object{{"url", Json(std::move(url))}},
        std::move(options));
}

Result<MutationResult<BrowserSnapshot>> Browser::back(MutationOptions options) const {
    return mutate(Operation::browser_back, {}, std::move(options));
}

Result<MutationResult<BrowserSnapshot>> Browser::forward(MutationOptions options) const {
    return mutate(Operation::browser_forward, {}, std::move(options));
}

Result<MutationResult<BrowserSnapshot>> Browser::reload(MutationOptions options) const {
    return mutate(Operation::browser_reload, {}, std::move(options));
}

Result<MutationResult<BrowserSnapshot>> Browser::activate(MutationOptions options) const {
    return mutate(Operation::browser_activate, {}, std::move(options));
}

Result<MutationResult<EmptyResult>> Browser::key(
    Json::Object params,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_key, std::move(params), std::move(options));
}

Result<MutationResult<EmptyResult>> Browser::text(
    std::string text,
    MutationOptions options) const {
    return mutate(
        Operation::browser_input_text,
        Json::Object{{"text", Json(std::move(text))}},
        std::move(options));
}

Result<MutationResult<EmptyResult>> Browser::mouse(
    Json::Object params,
    std::uint64_t pointer_frame_seq,
    MutationOptions options) const {
    params.insert_or_assign(
        "pointer_frame_seq",
        Json(std::to_string(pointer_frame_seq)));
    return mutate(
        Operation::browser_input_mouse,
        std::move(params),
        std::move(options));
}

Result<MutationResult<EmptyResult>> Browser::wheel(
    double delta_x,
    double delta_y,
    double x_px,
    double y_px,
    std::uint64_t pointer_frame_seq,
    MutationOptions options) const {
    if (!std::isfinite(delta_x) || !std::isfinite(delta_y) ||
        !std::isfinite(x_px) || !std::isfinite(y_px)) {
        return make_error(
            ErrorCode::invalid_argument,
            "browser wheel coordinates and deltas must be finite");
    }
    return mutate(
        Operation::browser_input_wheel,
        Json::Object{
            {"delta_x", Json(delta_x)},
            {"delta_y", Json(delta_y)},
            {"x_px", Json(x_px)},
            {"y_px", Json(y_px)},
            {
                "pointer_frame_seq",
                Json(std::to_string(pointer_frame_seq)),
            },
        },
        std::move(options));
}

Result<BrowserViewerResizeResult> Browser::resize_viewer(
    std::string attachment_lease,
    std::uint32_t width_px,
    std::uint32_t height_px) const {
    if (width_px == 0 || height_px == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "browser pixel dimensions must be positive");
    }
    if (attachment_lease.empty() || attachment_lease.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "attachment lease must contain 1 to 128 bytes");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::browser_viewer_resize,
        routed_params(Json::Object{
            {"attachment_lease", Json(std::move(attachment_lease))},
            {"width_px", Json(static_cast<std::uint64_t>(width_px))},
            {"height_px", Json(static_cast<std::uint64_t>(height_px))},
        }),
        {}));
}

Result<ViewerReleaseResult> Browser::release_viewer(
    std::string attachment_lease) const {
    if (attachment_lease.empty() || attachment_lease.size() > 128) {
        return make_error(
            ErrorCode::invalid_argument,
            "attachment lease must contain 1 to 128 bytes");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::browser_viewer_release,
        routed_params(Json::Object{
            {"attachment_lease", Json(std::move(attachment_lease))},
        }),
        {}));
}

Result<BrowserAttachmentStream> Browser::attach(
    Json::Object params,
    CallOptions call) const {
    params = routed_params(std::move(params));
    auto stream = detail::resource_open_stream(
        state_,
        Operation::browser_attach,
        std::move(params),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return BrowserAttachmentStream(std::move(stream).value());
}

Result<MutationResult<EmptyResult>> Browser::close(MutationOptions options) const {
    return mutate(Operation::browser_close, {}, std::move(options));
}

Result<ClientSnapshot> ConnectedClient::refresh() const {
    return read(Operation::client_get);
}

Result<ClientSnapshot> ConnectedClient::update_metadata(
    ClientMetadataUpdate update) const {
    Json::Object params;
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
    if (params.empty()) {
        return make_error(
            ErrorCode::invalid_argument,
            "client metadata update must change name or kind");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::client_metadata_update,
        routed_params(std::move(params)),
        {}));
}

Result<ClientSnapshot> ConnectedClient::set_name(std::string name) const {
    return update_metadata(
        ClientMetadataUpdate{.name = OptionalStringUpdate::set(
                                 std::move(name))});
}

Result<ClientSnapshot> ConnectedClient::clear_name() const {
    return update_metadata(
        ClientMetadataUpdate{.name = OptionalStringUpdate::clear()});
}

Result<ClientSnapshot> ConnectedClient::set_kind(std::string kind) const {
    return update_metadata(
        ClientMetadataUpdate{.kind = OptionalStringUpdate::set(
                                 std::move(kind))});
}

Result<ClientSnapshot> ConnectedClient::clear_kind() const {
    return update_metadata(
        ClientMetadataUpdate{.kind = OptionalStringUpdate::clear()});
}

Result<ClientSnapshot> ConnectedClient::set_sizing(Json::Object params) const {
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::client_sizing_set,
        routed_params(std::move(params)),
        {}));
}

Result<ClientSnapshot> ConnectedClient::release_sizing(Json::Object params) const {
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::client_sizing_release,
        routed_params(std::move(params)),
        {}));
}

Result<CellPixelsResult> ConnectedClient::set_cell_pixels(
    std::uint32_t width_px,
    std::uint32_t height_px) const {
    if (width_px == 0 || height_px == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "cell pixel dimensions must be positive");
    }
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::client_cell_pixels_set,
        routed_params(Json::Object{
            {"width_px", Json(static_cast<std::uint64_t>(width_px))},
            {"height_px", Json(static_cast<std::uint64_t>(height_px))},
        }),
        {}));
}

Result<EmptyResult> ConnectedClient::detach() const {
    return detail::ResourceReadResult(detail::resource_control(
        state_,
        Operation::client_detach,
        routed_params(),
        {}));
}

Result<SidebarViewSnapshot> SidebarView::refresh() const {
    return read(Operation::sidebar_view_get);
}

Result<SidebarViewStream> SidebarView::attach(
    Json::Object params,
    CallOptions call) const {
    params = routed_params(std::move(params));
    auto stream = detail::resource_open_stream(
        state_,
        Operation::sidebar_view_attach,
        std::move(params),
        std::move(call));
    if (!stream) {
        return std::move(stream).error();
    }
    return SidebarViewStream(std::move(stream).value());
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

[[nodiscard]] Result<void> validate_embedded_error(const Json& error) {
    auto exact = require_exact_fields(
        error,
        {"code", "message", "details", "retryable"},
        "stream end error");
    if (!exact) {
        return std::move(exact).error();
    }
    auto code = require_string(error, "code");
    if (!code) {
        return std::move(code).error();
    }
    auto message = require_string(error, "message");
    if (!message) {
        return std::move(message).error();
    }
    if (!error.find("details")) {
        return make_error(
            ErrorCode::decode,
            "stream end error is missing details");
    }
    const Json* retryable = error.find("retryable");
    if (!retryable) {
        return make_error(
            ErrorCode::decode,
            "stream end error is missing retryable");
    }
    auto parsed_retryable = retryable->as_bool();
    if (!parsed_retryable) {
        return make_error(
            ErrorCode::decode,
            "stream end error retryable must be boolean");
    }
    return {};
}

[[nodiscard]] Result<StreamEnd> decode_stream_end(
    const Json& envelope,
    const StreamId& expected_stream) {
    auto exact = require_exact_fields(
        envelope,
        {
            "protocol",
            "type",
            "stream_id",
            "reason",
            "cursor",
            "error",
            "recovery",
        },
        "stream end");
    if (!exact) {
        return std::move(exact).error();
    }
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/2") {
        return make_error(
            ErrorCode::protocol,
            "stream end protocol must be cmux.protocol/2");
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
    if (const Json* cursor = envelope.find("cursor")) {
        if (cursor->is_null()) {
            return make_error(
                ErrorCode::decode,
                "stream end cursor must not be null");
        }
        auto parsed = parse_cursor(*cursor);
        if (!parsed) {
            return std::move(parsed).error();
        }
        decoded.cursor = std::move(parsed).value();
    }
    if (const Json* recovery = envelope.find("recovery")) {
        auto text = recovery->as_string();
        if (!text) {
            return make_error(
                ErrorCode::decode,
                "stream end recovery must be a string");
        }
        decoded.recovery = std::string(text.value());
    }
    if (const Json* error = envelope.find("error")) {
        if (error->is_null()) {
            return make_error(
                ErrorCode::decode,
                "stream end error must not be null");
        }
        auto valid = validate_embedded_error(*error);
        if (!valid) {
            return std::move(valid).error();
        }
        decoded.error = decode_embedded_error(*error, envelope);
    }
    if ((decoded.reason == StreamEndReason::error) != decoded.error.has_value()) {
        return make_error(
            ErrorCode::decode,
            "stream end error is required exactly when reason is error");
    }
    return decoded;
}

[[nodiscard]] Result<RawStreamItem> decode_stream_item(
    const Json& envelope,
    const StreamId& expected_stream) {
    auto exact = require_exact_fields(
        envelope,
        {"protocol", "type", "stream_id", "sequence", "cursor", "item"},
        "stream item");
    if (!exact) {
        return std::move(exact).error();
    }
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/2") {
        return make_error(
            ErrorCode::protocol,
            "stream item protocol must be cmux.protocol/2");
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
    if (const Json* cursor = envelope.find("cursor")) {
        if (cursor->is_null()) {
            return make_error(
                ErrorCode::decode,
                "stream item cursor must not be null");
        }
        auto parsed = parse_cursor(*cursor);
        if (!parsed) {
            return std::move(parsed).error();
        }
        decoded.cursor = std::move(parsed).value();
    }
    return decoded;
}

using StreamItemValidator = Result<void> (*)(
    const Json&,
    const std::optional<Cursor>&);

template <typename T>
[[nodiscard]] Result<void> validate_typed_stream_item(
    const Json& value,
    const std::optional<Cursor>& cursor) {
    auto decoded = detail::decode_stream_domain<T>(value, cursor);
    if (!decoded) {
        return std::move(decoded).error();
    }
    return {};
}

[[nodiscard]] StreamItemValidator stream_item_validator(
    Operation operation) noexcept {
    switch (operation) {
        case Operation::session_events:
            return &validate_typed_stream_item<SessionEvent>;
        case Operation::session_journal_subscribe:
            return &validate_typed_stream_item<SessionJournalRecord>;
        case Operation::terminal_attach:
            return &validate_typed_stream_item<TerminalAttachmentItem>;
        case Operation::browser_attach:
            return &validate_typed_stream_item<BrowserAttachmentItem>;
        case Operation::sidebar_view_attach:
            return &validate_typed_stream_item<SidebarViewItem>;
        default:
            return nullptr;
    }
}

[[nodiscard]] Result<std::string> envelope_type(const Json& envelope) {
    auto protocol = require_string(envelope, "protocol");
    if (!protocol || protocol.value() != "cmux.protocol/2") {
        return make_error(
            ErrorCode::protocol,
            "server protocol must be cmux.protocol/2");
    }
    return require_string(envelope, "type");
}

}  // namespace

namespace {

class TransportCloseGuard {
public:
    explicit TransportCloseGuard(Transport* transport) noexcept
        : transport_(transport) {}

    TransportCloseGuard(const TransportCloseGuard&) = delete;
    TransportCloseGuard& operator=(const TransportCloseGuard&) = delete;

    ~TransportCloseGuard() {
        if (transport_) {
            transport_->close();
        }
    }

    void release() noexcept { transport_ = nullptr; }

private:
    Transport* transport_;
};

}  // namespace

struct ResourceStream::Impl {
    static constexpr std::size_t max_buffered_messages = 256U;
    static constexpr std::size_t max_buffered_bytes = 16U * 1024U * 1024U;

    struct BufferedEnvelope {
        Json envelope;
        std::size_t bytes = 0;
    };

    std::unique_ptr<Transport> transport;
    ClientOptions options;
    StreamId stream_id;
    std::optional<std::string> attachment_lease;
    std::string machine_selector;
    std::string session_selector;
    Json::Object connection_route;
    std::deque<BufferedEnvelope> buffered;
    std::size_t buffered_bytes = 0;
    std::optional<StreamEnd> stream_end;
    std::atomic<std::uint64_t> next_request_id{1};
    std::mutex mutex;
    bool transport_closed = false;
    bool cancel_started = false;
    std::optional<Error> cancel_failure;
    StreamItemValidator item_validator = nullptr;

    ~Impl() { close_transport(); }

    [[nodiscard]] Result<BufferedEnvelope> receive(Timeout timeout) {
        auto wire = transport->receive(timeout);
        if (!wire) {
            return std::move(wire).error();
        }
        const auto bytes = wire.value().size();
        auto parsed = Json::parse(wire.value(), options.json_limits);
        if (!parsed) {
            return std::move(parsed).error();
        }
        return BufferedEnvelope{std::move(parsed).value(), bytes};
    }

    [[nodiscard]] Result<BufferedEnvelope> receive() {
        return receive(options.timeout);
    }

    [[nodiscard]] Result<void> buffer(BufferedEnvelope envelope) {
        if (
            buffered.size() >= max_buffered_messages
            || envelope.bytes > max_buffered_bytes - buffered_bytes) {
            return make_error(
                ErrorCode::stream_local_overflow,
                "stream buffer exceeded 256 envelopes or 16 MiB");
        }
        buffered_bytes += envelope.bytes;
        buffered.push_back(std::move(envelope));
        return {};
    }

    [[nodiscard]] BufferedEnvelope pop_buffered() {
        auto envelope = std::move(buffered.front());
        buffered.pop_front();
        buffered_bytes -= envelope.bytes;
        return envelope;
    }

    [[nodiscard]] std::string request_id(std::string_view purpose) {
        return "cpp-stream-" + std::string(purpose) + "-" +
               std::to_string(
                   next_request_id.fetch_add(1, std::memory_order_relaxed));
    }

    void close_transport() noexcept {
        if (!transport_closed) {
            transport_closed = true;
            if (transport) {
                transport->close();
            }
        }
    }

    [[nodiscard]] Error fail_closed(Error error) {
        buffered.clear();
        buffered_bytes = 0;
        close_transport();
        return error;
    }

    [[nodiscard]] Result<void> validate_item(
        const RawStreamItem& item) const {
        if (!item_validator) {
            return make_error(
                ErrorCode::decode,
                "stream has no typed item validator");
        }
        return item_validator(item.value, item.cursor);
    }
};

Result<std::unique_ptr<ResourceStream::Impl>>
detail::ResourceClientState::open_stream(
    Operation operation,
    Json::Object params,
    CallOptions call) {
    if (is_closed.load(std::memory_order_acquire)) {
        return make_error(ErrorCode::closed, "client is closed");
    }
    if (!stream_factory) {
        return make_error(
            ErrorCode::unsupported,
            "this client has no stream transport factory");
    }
    auto transport_result = stream_factory();
    if (!transport_result) {
        return std::move(transport_result).error();
    }
    auto transport = std::move(transport_result).value();
    if (!transport) {
        return make_error(
            ErrorCode::connection,
            "stream transport factory returned null");
    }
    TransportCloseGuard close_on_failure(transport.get());
    auto stream_value = make_stream_value();
    auto parsed_id = StreamId::parse(stream_value);
    if (!parsed_id) {
        return std::move(parsed_id).error();
    }
    params.insert_or_assign("stream_id", Json(stream_value));
    inject_routing(options, operation, params);
    if (call.cancel.stop_requested()) {
        return make_error(ErrorCode::canceled, "stream open was canceled");
    }
    const auto deadline = call.deadline.value_or(
        std::chrono::steady_clock::now() + options.timeout);
    const auto remaining = [&]() -> Timeout {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            return Timeout::zero();
        }
        return std::max(
            Timeout(1),
            std::chrono::duration_cast<Timeout>(deadline - now));
    };
    const auto machine = params.find("machine");
    const auto session = params.find("session");
    if (machine == params.end() || session == params.end()) {
        return make_error(
            ErrorCode::decode,
            "stream route requires machine and session selectors");
    }
    auto machine_selector = machine->second.as_string();
    auto session_selector = session->second.as_string();
    if (!machine_selector || !session_selector) {
        return make_error(
            ErrorCode::decode,
            "stream route selectors must be strings");
    }
    auto impl = std::make_unique<ResourceStream::Impl>();
    impl->transport = std::move(transport);
    close_on_failure.release();
    impl->options = options;
    impl->stream_id = std::move(parsed_id).value();
    impl->item_validator = stream_item_validator(operation);
    if (!impl->item_validator) {
        return make_error(
            ErrorCode::invalid_argument,
            "stream operation has no typed item decoder");
    }
    impl->machine_selector = std::string(machine_selector.value());
    impl->session_selector = std::string(session_selector.value());
    constexpr std::array<std::string_view, 10> route_fields{
        "machine",
        "session",
        "workspace",
        "screen",
        "pane",
        "tab",
        "terminal",
        "browser",
        "client",
        "sidebar_view",
    };
    for (const auto key : route_fields) {
        if (const auto found = params.find(key); found != params.end()) {
            impl->connection_route.emplace(found->first, found->second);
        }
    }
    const auto request_id = impl->request_id("open");
    auto sent = send_envelope(
        *impl->transport,
        request_id,
        operation,
        std::move(params),
        std::nullopt,
        remaining(),
        options.json_limits);
    if (!sent) {
        return std::move(sent).error();
    }
    while (true) {
        if (call.cancel.stop_requested()) {
            return make_error(ErrorCode::canceled, "stream open was canceled");
        }
        auto timeout = remaining();
        if (timeout == Timeout::zero()) {
            return make_error(ErrorCode::timeout, "stream open timed out");
        }
        if (call.cancel.stop_possible()) {
            timeout = std::min(timeout, Timeout(25));
        }
        auto received = impl->receive(timeout);
        if (!received) {
            if (received.error().code == ErrorCode::timeout &&
                call.cancel.stop_possible() &&
                remaining() != Timeout::zero()) {
                continue;
            }
            return std::move(received).error();
        }
        auto envelope = std::move(received).value();
        auto type = envelope_type(envelope.envelope);
        if (!type) {
            return std::move(type).error();
        }
        if (type.value() == "response") {
            auto response = decode_response(
                envelope.envelope, request_id, "stream open response");
            if (!response) {
                return std::move(response).error();
            }
            const bool view_attachment =
                operation == Operation::terminal_attach ||
                operation == Operation::browser_attach;
            auto exact = require_exact_fields(
                response.value(),
                view_attachment
                    ? std::initializer_list<std::string_view>{
                          "stream_id", "attachment_lease"}
                    : std::initializer_list<std::string_view>{
                          "stream_id", "cursor"},
                "stream open result");
            if (!exact) {
                return std::move(exact).error();
            }
            auto opened_id = require_string(response.value(), "stream_id");
            if (!opened_id ||
                opened_id.value() != impl->stream_id.value()) {
                return make_error(
                    ErrorCode::protocol,
                    "stream open result ID mismatch");
            }
            if (view_attachment) {
                auto lease = require_string(
                    response.value(), "attachment_lease");
                if (!lease || lease.value().empty() || lease.value().size() > 128) {
                    return make_error(
                        ErrorCode::decode,
                        "stream attachment lease must contain 1 to 128 bytes");
                }
                impl->attachment_lease = std::string(lease.value());
            }
            if (!view_attachment) {
                const Json* cursor = response.value().find("cursor");
                if (!cursor) {
                    return impl;
                }
                if (cursor->is_null()) {
                    return make_error(
                        ErrorCode::decode,
                        "stream open cursor must not be null");
                }
                auto parsed = parse_cursor(*cursor);
                if (!parsed) {
                    return std::move(parsed).error();
                }
            }
            return impl;
        }
        if (type.value() != "stream_item" &&
            type.value() != "stream_end") {
            return make_error(
                ErrorCode::protocol,
                "stream open received an unexpected envelope");
        }
        if (type.value() == "stream_item") {
            auto valid = decode_stream_item(
                envelope.envelope, impl->stream_id);
            if (!valid) {
                return std::move(valid).error();
            }
        } else {
            auto valid = decode_stream_end(
                envelope.envelope, impl->stream_id);
            if (!valid) {
                return std::move(valid).error();
            }
        }
        auto buffered = impl->buffer(std::move(envelope));
        if (!buffered) {
            return std::move(buffered).error();
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

const std::optional<std::string>& ResourceStream::attachment_lease() const noexcept {
    static const std::optional<std::string> empty;
    return impl_ ? impl_->attachment_lease : empty;
}

Result<std::optional<RawStreamItem>> ResourceStream::next() {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    while (true) {
        auto item = next(impl_->options.timeout);
        if (item || item.error().code != ErrorCode::timeout) {
            return item;
        }
    }
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
        envelope = std::move(impl_->pop_buffered().envelope);
    } else {
        auto wire = impl_->transport->receive(timeout);
        if (!wire) {
            if (wire.error().code != ErrorCode::timeout) {
                return impl_->fail_closed(std::move(wire).error());
            }
            return std::move(wire).error();
        }
        auto parsed = Json::parse(wire.value(), impl_->options.json_limits);
        if (!parsed) {
            return impl_->fail_closed(std::move(parsed).error());
        }
        envelope = std::move(parsed).value();
    }
    auto type = envelope_type(envelope);
    if (!type) {
        return impl_->fail_closed(std::move(type).error());
    }
    if (type.value() == "stream_end") {
        auto end = decode_stream_end(envelope, impl_->stream_id);
        if (!end) {
            return impl_->fail_closed(std::move(end).error());
        }
        impl_->stream_end = std::move(end).value();
        impl_->close_transport();
        return std::optional<RawStreamItem>{};
    }
    if (type.value() != "stream_item") {
        return impl_->fail_closed(make_error(
            ErrorCode::protocol,
            "stream connection received an unexpected envelope"));
    }
    auto item = decode_stream_item(envelope, impl_->stream_id);
    if (!item) {
        return impl_->fail_closed(std::move(item).error());
    }
    auto typed = impl_->validate_item(item.value());
    if (!typed) {
        return impl_->fail_closed(std::move(typed).error());
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
    for (const auto& [key, value] : impl_->connection_route) {
        params.insert_or_assign(key, value);
    }
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
        return impl_->fail_closed(std::move(sent).error());
    }
    while (true) {
        auto received = impl_->receive();
        if (!received) {
            return impl_->fail_closed(std::move(received).error());
        }
        auto envelope = std::move(received).value();
        auto type = envelope_type(envelope.envelope);
        if (!type) {
            return impl_->fail_closed(std::move(type).error());
        }
        if (type.value() == "response") {
            auto response = decode_response(
                envelope.envelope, request_id, "stream control response");
            if (!response && response.error().code != ErrorCode::command) {
                return impl_->fail_closed(std::move(response).error());
            }
            return response;
        }
        if (type.value() == "stream_item" || type.value() == "stream_end") {
            if (type.value() == "stream_item") {
                auto valid = decode_stream_item(
                    envelope.envelope, impl_->stream_id);
                if (!valid) {
                    return impl_->fail_closed(std::move(valid).error());
                }
            } else {
                auto valid = decode_stream_end(
                    envelope.envelope, impl_->stream_id);
                if (!valid) {
                    return impl_->fail_closed(std::move(valid).error());
                }
            }
            auto buffered = impl_->buffer(std::move(envelope));
            if (!buffered) {
                return impl_->fail_closed(std::move(buffered).error());
            }
            continue;
        }
        return impl_->fail_closed(make_error(
            ErrorCode::protocol,
            "stream control received an unexpected envelope"));
    }
}

Result<ViewerResizeResult> TerminalAttachmentStream::resize_viewer(
    std::uint16_t columns,
    std::uint16_t rows) {
    if (columns == 0 || rows == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "terminal cell dimensions must be positive");
    }
    const auto& lease = stream_.attachment_lease();
    if (!lease) {
        return make_error(ErrorCode::decode, "terminal attachment has no lease");
    }
    return detail::ResourceReadResult(stream_.connection_control(
        Operation::terminal_viewer_resize,
        Json::Object{
            {"attachment_lease", Json(*lease)},
            {"cols", Json(static_cast<std::uint64_t>(columns))},
            {"rows", Json(static_cast<std::uint64_t>(rows))},
        }));
}

Result<ViewerReleaseResult> TerminalAttachmentStream::release_viewer() {
    const auto& lease = stream_.attachment_lease();
    if (!lease) {
        return make_error(ErrorCode::decode, "terminal attachment has no lease");
    }
    return detail::ResourceReadResult(stream_.connection_control(
        Operation::terminal_viewer_release,
        Json::Object{{"attachment_lease", Json(*lease)}}));
}

Result<BrowserViewerResizeResult> BrowserAttachmentStream::resize_viewer(
    std::uint32_t width_px,
    std::uint32_t height_px) {
    if (width_px == 0 || height_px == 0) {
        return make_error(
            ErrorCode::invalid_argument,
            "browser pixel dimensions must be positive");
    }
    const auto& lease = stream_.attachment_lease();
    if (!lease) {
        return make_error(ErrorCode::decode, "browser attachment has no lease");
    }
    return detail::ResourceReadResult(stream_.connection_control(
        Operation::browser_viewer_resize,
        Json::Object{
            {"attachment_lease", Json(*lease)},
            {"width_px", Json(static_cast<std::uint64_t>(width_px))},
            {"height_px", Json(static_cast<std::uint64_t>(height_px))},
        }));
}

Result<ViewerReleaseResult> BrowserAttachmentStream::release_viewer() {
    const auto& lease = stream_.attachment_lease();
    if (!lease) {
        return make_error(ErrorCode::decode, "browser attachment has no lease");
    }
    return detail::ResourceReadResult(stream_.connection_control(
        Operation::browser_viewer_release,
        Json::Object{{"attachment_lease", Json(*lease)}}));
}

Result<StreamEnd> ResourceStream::cancel() {
    if (!impl_) {
        return make_error(ErrorCode::closed, "stream is not initialized");
    }
    std::lock_guard lock(impl_->mutex);
    if (impl_->stream_end) {
        return *impl_->stream_end;
    }
    if (impl_->cancel_failure) {
        return *impl_->cancel_failure;
    }
    if (impl_->transport_closed) {
        return make_error(ErrorCode::closed, "stream connection is closed");
    }
    if (impl_->cancel_started) {
        return make_error(
            ErrorCode::closed,
            "stream cancellation has already started");
    }
    impl_->cancel_started = true;
    const auto fail_cancel = [&](Error error) -> Result<StreamEnd> {
        error = impl_->fail_closed(std::move(error));
        impl_->cancel_failure = error;
        return error;
    };
    const auto deadline =
        std::chrono::steady_clock::now() + impl_->options.timeout;
    const auto remaining = [&]() -> Timeout {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            return Timeout::zero();
        }
        return std::max(
            Timeout(1),
            std::chrono::duration_cast<Timeout>(deadline - now));
    };
    const auto request_id = impl_->request_id("cancel");
    Json::Object params{
        {"machine", Json(impl_->machine_selector)},
        {"session", Json(impl_->session_selector)},
        {"stream", Json(impl_->stream_id.value())},
    };
    auto sent = detail::ResourceClientState::send_envelope(
        *impl_->transport,
        request_id,
        Operation::stream_cancel,
        std::move(params),
        std::nullopt,
        remaining(),
        impl_->options.json_limits);
    if (!sent) {
        return fail_cancel(std::move(sent).error());
    }
    bool response_seen = false;
    std::optional<StreamEnd> end;
    while (!response_seen || !end) {
        const auto timeout = remaining();
        if (timeout == Timeout::zero()) {
            return fail_cancel(make_error(
                ErrorCode::timeout,
                "stream cancellation timed out"));
        }
        Json envelope;
        if (!impl_->buffered.empty()) {
            envelope = std::move(impl_->pop_buffered().envelope);
        } else {
            auto received = impl_->receive(timeout);
            if (!received) {
                return fail_cancel(std::move(received).error());
            }
            envelope = std::move(received).value().envelope;
        }
        if (remaining() == Timeout::zero()) {
            return fail_cancel(make_error(
                ErrorCode::timeout,
                "stream cancellation timed out"));
        }
        auto type = envelope_type(envelope);
        if (!type) {
            return fail_cancel(std::move(type).error());
        }
        if (type.value() == "response") {
            if (response_seen) {
                return fail_cancel(make_error(
                    ErrorCode::protocol,
                    "stream cancellation received duplicate response"));
            }
            auto response = decode_response(
                envelope, request_id, "stream cancel response");
            if (!response) {
                return fail_cancel(std::move(response).error());
            }
            auto exact = require_exact_fields(
                response.value(), {}, "stream cancel result");
            if (!exact) {
                return fail_cancel(std::move(exact).error());
            }
            response_seen = true;
            continue;
        }
        if (type.value() == "stream_end") {
            if (end) {
                return fail_cancel(make_error(
                    ErrorCode::protocol,
                    "stream cancellation received duplicate stream end"));
            }
            auto decoded = decode_stream_end(envelope, impl_->stream_id);
            if (!decoded) {
                return fail_cancel(std::move(decoded).error());
            }
            if (decoded.value().reason != StreamEndReason::canceled) {
                return fail_cancel(make_error(
                    ErrorCode::protocol,
                    "stream cancellation requires a canceled stream end"));
            }
            end = std::move(decoded).value();
            continue;
        }
        if (type.value() == "stream_item") {
            if (end) {
                return fail_cancel(make_error(
                    ErrorCode::protocol,
                    "stream cancellation received an item after stream end"));
            }
            auto decoded = decode_stream_item(envelope, impl_->stream_id);
            if (!decoded) {
                return fail_cancel(std::move(decoded).error());
            }
            auto typed = impl_->validate_item(decoded.value());
            if (!typed) {
                return fail_cancel(std::move(typed).error());
            }
            // Items already queued before cancellation are intentionally
            // dropped.
            continue;
        }
        return fail_cancel(make_error(
            ErrorCode::protocol,
            "stream cancellation received an unexpected envelope"));
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
    Json::Object params,
    CallOptions call) {
    if (!state) {
        return make_error(ErrorCode::closed, "client is not initialized");
    }
    if (operation_class(operation) != OperationClass::stream_open) {
        return wrong_class(operation, OperationClass::stream_open);
    }
    auto opened =
        state->open_stream(operation, std::move(params), std::move(call));
    if (!opened) {
        return std::move(opened).error();
    }
    return ResourceStream(std::move(opened).value());
}

}  // namespace detail

}  // namespace cmux
