#include <cmux/client.hpp>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>
#include <vector>

namespace {

class AdapterError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

[[nodiscard]] std::string describe(const cmux::Error& error) {
    std::string result = error.protocol_code.empty()
        ? error.code_name()
        : error.protocol_code;
    result += ": ";
    result += error.message;
    return result;
}

template <typename T>
[[nodiscard]] T take(cmux::Result<T> result) {
    if (!result) {
        throw AdapterError(describe(result.error()));
    }
    return std::move(result).value();
}

[[nodiscard]] const cmux::Json& field(
    const cmux::Json& value,
    std::string_view name) {
    const auto* result = value.find(name);
    if (!result) {
        throw AdapterError("missing JSON field: " + std::string(name));
    }
    return *result;
}

[[nodiscard]] std::string string_value(const cmux::Json& value) {
    auto text = value.as_string();
    if (!text) {
        throw AdapterError("expected a JSON string");
    }
    return std::string(text.value());
}

[[nodiscard]] std::string string_field(
    const cmux::Json& value,
    std::string_view name) {
    return string_value(field(value, name));
}

[[nodiscard]] std::uint64_t decimal(std::string_view text) {
    std::uint64_t value = 0;
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc{} || end != text.data() + text.size()) {
        throw AdapterError("invalid unsigned decimal: " + std::string(text));
    }
    return value;
}

template <typename Id>
[[nodiscard]] Id opaque_id(std::string_view value) {
    auto parsed = Id::parse(value);
    if (!parsed) {
        throw AdapterError(describe(parsed.error()));
    }
    return std::move(parsed).value();
}

[[nodiscard]] const cmux::Json& constants(const cmux::Json& request) {
    return field(request, "constants");
}

[[nodiscard]] cmux::MutationOptions mutation_options(
    const cmux::Json& request,
    std::string_view key_name = "idempotency_key") {
    const auto& values = constants(request);
    auto options = take(cmux::MutationOptions::with_key(
        string_field(values, key_name)));
    return options.expecting(decimal(string_field(values, "revision")));
}

[[nodiscard]] cmux::Client connect(
    const cmux::Json& request,
    std::string session_selector) {
    cmux::ClientOptions options;
    options.socket_path = string_field(request, "socket_path");
    options.machine_selector = "current";
    options.session_selector = std::move(session_selector);
    options.timeout = std::chrono::seconds(15);
    return take(cmux::Client::connect(std::move(options)));
}

[[nodiscard]] cmux::Session session(
    cmux::Client& client,
    const cmux::Json& request) {
    return client.session(opaque_id<cmux::SessionId>(
        string_field(constants(request), "session")));
}

[[nodiscard]] cmux::Workspace workspace(
    cmux::Client& client,
    const cmux::Json& request) {
    return client.workspace(opaque_id<cmux::WorkspaceId>(
        string_field(constants(request), "workspace")));
}

[[nodiscard]] std::string end_name(cmux::StreamEndReason reason) {
    switch (reason) {
        case cmux::StreamEndReason::completed:
            return "completed";
        case cmux::StreamEndReason::canceled:
            return "canceled";
        case cmux::StreamEndReason::closed:
            return "closed";
        case cmux::StreamEndReason::gap:
            return "gap";
        case cmux::StreamEndReason::error:
            return "error";
    }
    throw AdapterError("unknown stream end reason");
}

[[nodiscard]] const cmux::StreamEnd& require_end(
    const cmux::SessionEventStream& stream) {
    if (!stream.end()) {
        throw AdapterError("stream ended without terminal metadata");
    }
    return *stream.end();
}

[[nodiscard]] cmux::Json cursor_json(const cmux::Cursor& cursor) {
    return cmux::Json(cmux::Json::Object{
        {"generation", cmux::Json(cursor.generation)},
        {"revision", cmux::Json(std::to_string(cursor.revision))},
    });
}

[[nodiscard]] cmux::Json mutation_json(
    const cmux::MutationResult<cmux::WorkspaceSnapshot>& result) {
    return cmux::Json(cmux::Json::Object{
        {"workspace_id", cmux::Json(result.value.id.value())},
        {"name", cmux::Json(result.value.name)},
        {"generation", cmux::Json(result.generation)},
        {"revision", cmux::Json(std::to_string(result.revision))},
        {"replayed", cmux::Json(result.replayed)},
    });
}

[[nodiscard]] cmux::Json error_json(const cmux::Error& error) {
    return cmux::Json(cmux::Json::Object{
        {"code", cmux::Json(error.protocol_code)},
        {"message", cmux::Json(error.message)},
        {"details",
         error.details ? *error.details : cmux::Json(cmux::Json::Object{})},
        {"retryable", cmux::Json(error.retryable)},
    });
}

[[nodiscard]] cmux::Json created_path_json(const cmux::CreatedPath& path) {
    if (const auto* value =
            std::get_if<cmux::CreatedWorkspaceOnly>(&path)) {
        return cmux::Json(cmux::Json::Object{
            {"kind", cmux::Json("workspace")},
            {"workspace_id", cmux::Json(value->workspace_id.value())},
        });
    }
    if (const auto* value =
            std::get_if<cmux::CreatedTerminalPath>(&path)) {
        return cmux::Json(cmux::Json::Object{
            {"kind", cmux::Json("terminal")},
            {"workspace_id", cmux::Json(value->workspace_id.value())},
            {"screen_id", cmux::Json(value->screen_id.value())},
            {"pane_id", cmux::Json(value->pane_id.value())},
            {"tab_id", cmux::Json(value->tab_id.value())},
            {"terminal_id", cmux::Json(value->terminal_id.value())},
        });
    }
    const auto& value = std::get<cmux::CreatedBrowserPath>(path);
    return cmux::Json(cmux::Json::Object{
        {"kind", cmux::Json("browser")},
        {"workspace_id", cmux::Json(value.workspace_id.value())},
        {"screen_id", cmux::Json(value.screen_id.value())},
        {"pane_id", cmux::Json(value.pane_id.value())},
        {"tab_id", cmux::Json(value.tab_id.value())},
        {"browser_id", cmux::Json(value.browser_id.value())},
    });
}

[[nodiscard]] std::string creation_state_name(cmux::CreationState state) {
    switch (state) {
        case cmux::CreationState::pending:
            return "pending";
        case cmux::CreationState::created:
            return "created";
        case cmux::CreationState::not_applied:
            return "not_applied";
        case cmux::CreationState::indeterminate:
            return "indeterminate";
    }
    throw AdapterError("unknown creation state");
}

[[nodiscard]] std::string creation_recovery_name(
    cmux::CreationRecovery recovery) {
    switch (recovery) {
        case cmux::CreationRecovery::retry_same_idempotency_key:
            return "retry_same_idempotency_key";
        case cmux::CreationRecovery::retry_new_idempotency_key:
            return "retry_new_idempotency_key";
        case cmux::CreationRecovery::wait:
            return "wait";
        case cmux::CreationRecovery::none:
            return "none";
        case cmux::CreationRecovery::do_not_retry:
            return "do_not_retry";
    }
    throw AdapterError("unknown creation recovery");
}

[[nodiscard]] cmux::Json creation_resolution_json(
    const cmux::CreationResolution& resolution) {
    cmux::Json::Object result{
        {"correlation_key", cmux::Json(resolution.correlation_key)},
        {"state", cmux::Json(creation_state_name(resolution.state))},
        {"recovery", cmux::Json(creation_recovery_name(resolution.recovery))},
    };
    if (resolution.operation) {
        result.emplace("operation", cmux::Json(*resolution.operation));
    }
    if (resolution.idempotency_key) {
        result.emplace(
            "idempotency_key",
            cmux::Json(*resolution.idempotency_key));
    }
    if (resolution.created_path) {
        result.emplace(
            "created_path",
            created_path_json(*resolution.created_path));
    }
    if (resolution.generation) {
        result.emplace("generation", cmux::Json(*resolution.generation));
    }
    if (resolution.revision) {
        result.emplace(
            "revision",
            cmux::Json(std::to_string(*resolution.revision)));
    }
    return cmux::Json(std::move(result));
}

[[nodiscard]] cmux::Json exit_outcome_json(
    const cmux::TerminalExitOutcome& outcome) {
    if (const auto* value = std::get_if<cmux::TerminalExitCode>(&outcome)) {
        return cmux::Json(cmux::Json::Object{
            {"kind", cmux::Json("exit")},
            {"code", cmux::Json(std::int64_t{value->code})},
        });
    }
    if (const auto* value =
            std::get_if<cmux::TerminalExitSignal>(&outcome)) {
        return cmux::Json(cmux::Json::Object{
            {"kind", cmux::Json("signal")},
            {"signal", cmux::Json(std::int64_t{value->signal})},
            {"core_dumped", cmux::Json(value->core_dumped)},
        });
    }
    const auto& value = std::get<cmux::TerminalExitUnknown>(outcome);
    return cmux::Json(cmux::Json::Object{
        {"kind", cmux::Json("unknown")},
        {"reason", cmux::Json(value.reason)},
    });
}

[[nodiscard]] cmux::Json terminal_wait_exit_json(
    const cmux::TerminalWaitExitResult& result) {
    if (const auto* value =
            std::get_if<cmux::TerminalWaitExitPending>(&result)) {
        return cmux::Json(cmux::Json::Object{
            {"state", cmux::Json("pending")},
            {"terminal_id", cmux::Json(value->terminal_id.value())},
            {"lifecycle", cmux::Json(value->lifecycle)},
            {"revision", cmux::Json(std::to_string(value->revision))},
        });
    }
    const auto& value = std::get<cmux::TerminalWaitExitExited>(result);
    return cmux::Json(cmux::Json::Object{
        {"state", cmux::Json("exited")},
        {"terminal_id", cmux::Json(value.terminal_id.value())},
        {"lifecycle", cmux::Json("exited")},
        {"outcome", exit_outcome_json(value.outcome)},
        {"exited_at", cmux::Json(std::to_string(value.exited_at))},
        {"revision", cmux::Json(std::to_string(value.revision))},
    });
}

[[nodiscard]] cmux::Json run_read(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    const auto result = take(session(client, request).ping());
    return cmux::Json(cmux::Json::Object{
        {"alive", cmux::Json(result.alive)},
        {"cursor", cursor_json(result.cursor)},
    });
}

[[nodiscard]] cmux::Json run_creation_resolve(
    const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    const auto result = take(session(client, request).resolve_creation(
        string_field(constants(request), "correlation_key")));
    return creation_resolution_json(result);
}

[[nodiscard]] cmux::Json run_creation_conflict(
    const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    cmux::CreateWorkspaceOptions create;
    create.name = string_field(constants(request), "name");
    create.initial_content = cmux::InitialContent::empty;
    create.correlation_key =
        string_field(constants(request), "correlation_key");
    auto result = session(client, request).create_workspace(
        std::move(create),
        take(cmux::MutationOptions::with_key(
            string_field(constants(request), "idempotency_key"))));
    if (result) {
        throw AdapterError("creation conflict unexpectedly succeeded");
    }
    return error_json(result.error());
}

[[nodiscard]] cmux::Json run_terminal_wait_exit(
    const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto terminal = client.terminal(opaque_id<cmux::TerminalId>(
        string_field(constants(request), "terminal")));
    const auto timeout = decimal(string_field(request, "timeout_ms"));
    return terminal_wait_exit_json(take(terminal.wait_exit(timeout)));
}

[[nodiscard]] cmux::Json run_mutation_replay(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto target = workspace(client, request);
    const auto name = string_field(constants(request), "name");
    const auto options = mutation_options(request);
    const auto first = take(target.rename(name, options));
    const auto second = take(target.rename(name, options));
    return cmux::Json(cmux::Json::Object{
        {"first", mutation_json(first)},
        {"second", mutation_json(second)},
    });
}

[[nodiscard]] cmux::Json run_mutation_error(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto result = workspace(client, request).rename(
        string_field(constants(request), "name"),
        mutation_options(request));
    if (result) {
        throw AdapterError("mutation unexpectedly succeeded");
    }
    return error_json(result.error());
}

[[nodiscard]] cmux::Json run_stream_unknown(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto stream = take(session(client, request).events());
    auto next = take(stream.next());
    if (!next) {
        throw AdapterError("unknown stream ended before its item");
    }
    if (!next->cursor) {
        throw AdapterError("unknown stream item omitted its cursor");
    }
    auto terminal = take(stream.next());
    if (terminal) {
        throw AdapterError("unknown stream produced an unexpected second item");
    }
    const auto* unknown = std::get_if<cmux::Unknown>(&next->value);
    if (!unknown) {
        throw AdapterError(
            "session event was not the public Unknown variant");
    }
    return cmux::Json(cmux::Json::Object{
        {"sequence", cmux::Json(std::to_string(next->sequence))},
        {"cursor", cursor_json(*next->cursor)},
        {"kind", cmux::Json(unknown->kind)},
        {"raw", unknown->raw},
        {"end", cmux::Json(end_name(require_end(stream).reason))},
    });
}

[[nodiscard]] cmux::Json run_stream_cancel(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto stream = take(session(client, request).events());
    const auto first = take(stream.cancel());
    const auto second = take(stream.cancel());
    std::uint64_t after = 0;
    while (take(stream.next())) {
        ++after;
    }
    if (first.reason != second.reason) {
        throw AdapterError("repeated cancel changed the terminal reason");
    }
    return cmux::Json(cmux::Json::Object{
        {"end", cmux::Json(end_name(second.reason))},
        {"items_after_cancel", cmux::Json(after)},
        {"cancel_calls", cmux::Json(std::uint64_t{2})},
    });
}

[[nodiscard]] std::string drain(cmux::SessionEventStream& stream) {
    while (take(stream.next())) {
    }
    return end_name(require_end(stream).reason);
}

[[nodiscard]] cmux::Json run_stream_overflow(const cmux::Json& request) {
    auto client = connect(
        request, string_field(constants(request), "session"));
    auto current_session = session(client, request);
    auto first = take(current_session.events());
    const auto first_end = drain(first);

    auto second = take(current_session.events());
    auto item = take(second.next());
    if (!item) {
        throw AdapterError("independent stream ended before its item");
    }
    const auto* unknown = std::get_if<cmux::Unknown>(&item->value);
    if (!unknown) {
        throw AdapterError(
            "independent stream item was not the public Unknown variant");
    }
    const auto second_kind = unknown->kind;
    if (take(second.next())) {
        throw AdapterError("independent stream produced an extra item");
    }
    const auto control = take(current_session.ping());
    return cmux::Json(cmux::Json::Object{
        {"first_end", cmux::Json(first_end)},
        {"second_kind", cmux::Json(second_kind)},
        {"control_alive", cmux::Json(control.alive)},
    });
}

[[nodiscard]] cmux::Json run_redaction() {
    constexpr std::string_view specifier_secret =
        "provider://conformance-secret";
    constexpr std::string_view renderer_secret =
        "renderer-conformance-secret";
    cmux::SensitiveString specifier{std::string(specifier_secret)};
    cmux::RendererGrant grant{
        "unix:///tmp/renderer",
        opaque_id<cmux::TerminalId>(
            "term_66666666666666666666666666666666"),
        cmux::SensitiveString(std::string(renderer_secret)),
        {"render"},
        1000,
    };
    std::ostringstream specifier_text;
    specifier_text << specifier;
    std::ostringstream grant_text;
    grant_text << grant;
    return cmux::Json(cmux::Json::Object{
        {"specifier_redacted",
         cmux::Json(
             specifier_text.str().find(specifier_secret) == std::string::npos)},
        {"renderer_token_redacted",
         cmux::Json(
             grant_text.str().find(renderer_secret) == std::string::npos)},
    });
}

[[nodiscard]] cmux::MutationOptions key(
    std::string_view prefix,
    std::string_view suffix) {
    return take(cmux::MutationOptions::with_key(
        std::string(prefix) + "-" + std::string(suffix)));
}

[[nodiscard]] cmux::WorkspaceId create_empty_workspace(
    cmux::Session& session,
    std::string name,
    cmux::MutationOptions mutation) {
    cmux::CreateWorkspaceOptions create;
    create.name = std::move(name);
    create.initial_content = cmux::InitialContent::empty;
    auto created = take(session.create_workspace(
        std::move(create), std::move(mutation)));
    return std::visit(
        [](const auto& value) { return value.workspace_id; },
        created.value);
}

[[nodiscard]] std::map<std::string, std::string> workspace_rows(
    cmux::Session& session) {
    const auto listed = take(session.workspaces());
    std::map<std::string, std::string> rows;
    for (const auto& item : listed) {
        rows.emplace(item.id.value(), item.name);
    }
    return rows;
}

[[nodiscard]] std::vector<std::string> string_array_field(
    const cmux::Json& value,
    std::string_view name) {
    auto array = field(value, name).as_array();
    if (!array) {
        throw AdapterError(
            "expected a JSON string array: " + std::string(name));
    }
    std::vector<std::string> result;
    result.reserve(array.value()->size());
    for (const auto& item : *array.value()) {
        result.push_back(string_value(item));
    }
    return result;
}

[[nodiscard]] cmux::Json string_array_json(
    const std::vector<std::string>& values) {
    cmux::Json::Array result;
    result.reserve(values.size());
    for (const auto& value : values) {
        result.emplace_back(value);
    }
    return cmux::Json(std::move(result));
}

[[nodiscard]] cmux::Json run_live_setup(const cmux::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(cmux::Selector<cmux::SessionId>::current());
    const auto pinged = take(current.ping()).alive;
    const auto base = string_field(request, "workspace_name");
    const auto key_prefix = string_field(request, "key_prefix");

    const auto stable_id = create_empty_workspace(
        current, base, key(key_prefix, "stable-create"));
    const auto renamed_name = base + "-renamed";
    const auto renamed = take(
        current.workspace(stable_id).rename(
            renamed_name,
            key(key_prefix, "stable-rename")));
    const auto stable_renamed = renamed.value.name == renamed_name;

    const auto duplicate_name = base + "-duplicate";
    std::vector<std::string> duplicate_ids;
    duplicate_ids.reserve(2);
    for (const auto suffix : {"duplicate-a", "duplicate-b"}) {
        duplicate_ids.push_back(
            create_empty_workspace(
                current,
                duplicate_name,
                key(key_prefix, suffix))
                .value());
    }

    auto ambiguity =
        current.workspace(
                   cmux::Selector<cmux::WorkspaceId>::exact_name(
                       duplicate_name))
            .rename(
                base + "-must-not-apply",
                key(key_prefix, "ambiguous-rename"));
    if (ambiguity) {
        throw AdapterError(
            "duplicate workspace selector unexpectedly mutated");
    }
    const auto ambiguity_code = ambiguity.error().protocol_code;
    std::vector<std::string> ambiguity_candidates;
    if (ambiguity.error().details) {
        if (const auto* candidates =
                ambiguity.error().details->find("candidates")) {
            auto array = candidates->as_array();
            if (array) {
                ambiguity_candidates.reserve(array.value()->size());
                for (const auto& candidate : *array.value()) {
                    ambiguity_candidates.push_back(string_value(candidate));
                }
            }
        }
    }
    const std::set<std::string> expected_candidates(
        duplicate_ids.begin(), duplicate_ids.end());
    const std::set<std::string> observed_candidates(
        ambiguity_candidates.begin(), ambiguity_candidates.end());
    const auto candidates_preserved =
        ambiguity_candidates.size() == duplicate_ids.size() &&
        observed_candidates == expected_candidates;

    const auto rows = workspace_rows(current);
    const auto no_mutation =
        rows.contains(stable_id.value()) &&
        rows.at(stable_id.value()) == renamed_name &&
        std::ranges::all_of(
            duplicate_ids,
            [&rows, &duplicate_name](const auto& identifier) {
                const auto found = rows.find(identifier);
                return found != rows.end() &&
                       found->second == duplicate_name;
            }) &&
        std::ranges::none_of(
            rows,
            [&base](const auto& entry) {
                return entry.second == base + "-must-not-apply";
            });

    return cmux::Json(cmux::Json::Object{
        {"pinged", cmux::Json(pinged)},
        {"stable_id", cmux::Json(stable_id.value())},
        {"stable_renamed", cmux::Json(stable_renamed)},
        {"duplicate_ids", string_array_json(duplicate_ids)},
        {"ambiguity_code", cmux::Json(ambiguity_code)},
        {"ambiguity_preserved_all_candidates",
         cmux::Json(candidates_preserved)},
        {"no_mutation", cmux::Json(no_mutation)},
    });
}

[[nodiscard]] const cmux::TerminalWaitExitPending& require_pending(
    const cmux::TerminalWaitExitResult& result) {
    const auto* value =
        std::get_if<cmux::TerminalWaitExitPending>(&result);
    if (!value) {
        throw AdapterError("terminal wait did not return pending");
    }
    return *value;
}

[[nodiscard]] const cmux::TerminalWaitExitExited& require_exited(
    const cmux::TerminalWaitExitResult& result) {
    const auto* value =
        std::get_if<cmux::TerminalWaitExitExited>(&result);
    if (!value) {
        throw AdapterError("terminal wait did not return an exit");
    }
    return *value;
}

[[nodiscard]] const cmux::TerminalExitCode& require_exit_code(
    const cmux::TerminalExitOutcome& outcome) {
    const auto* value = std::get_if<cmux::TerminalExitCode>(&outcome);
    if (!value) {
        throw AdapterError("terminal did not exit with an exit code");
    }
    return *value;
}

[[nodiscard]] cmux::Json run_live_creation_exit(
    const cmux::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(cmux::Selector<cmux::SessionId>::current());
    auto workspace = current.workspace(opaque_id<cmux::WorkspaceId>(
        string_field(request, "expected_stable_id")));
    const auto key_prefix = string_field(request, "key_prefix");
    const auto screen_created = take(workspace.create_screen(
        {},
        key(key_prefix, "runtime-screen")));
    const auto& screen_path = screen_created.value;
    auto pane = workspace.screen(screen_path.screen_id)
        .pane(screen_path.pane_id);

    const auto correlation_key =
        key_prefix + "-terminal-correlation";
    cmux::RunOptions run(take(cmux::RunCommand::shell(
        string_field(request, "exit_shell"))));
    run.correlation_key = correlation_key;
    const auto run_result = take(pane.run(
        std::move(run),
        key(key_prefix, "terminal-run")));
    const auto& path = run_result.value;
    auto terminal = client.terminal(path.terminal_id);

    const auto pending_result = take(terminal.wait_exit(decimal(
        string_field(request, "pending_timeout_ms"))));
    const auto& pending = require_pending(pending_result);
    const auto resolution =
        take(current.resolve_creation(correlation_key));
    if (!resolution.created_path) {
        throw AdapterError("creation resolution omitted its terminal path");
    }
    const auto* resolved =
        std::get_if<cmux::CreatedTerminalPath>(
            &*resolution.created_path);
    if (!resolved ||
        resolved->workspace_id != path.workspace_id ||
        resolved->screen_id != path.screen_id ||
        resolved->pane_id != path.pane_id ||
        resolved->tab_id != path.tab_id ||
        resolved->terminal_id != path.terminal_id) {
        throw AdapterError(
            "creation resolution returned a different terminal path");
    }
    if (!resolution.generation || !resolution.revision) {
        throw AdapterError(
            "created resolution omitted generation or revision");
    }

    const auto exit_result = take(terminal.wait_exit(decimal(
        string_field(request, "exit_timeout_ms"))));
    const auto& exited = require_exited(exit_result);
    const auto& exit_code = require_exit_code(exited.outcome);
    cmux::CreatedPath created_path = path;
    return cmux::Json(cmux::Json::Object{
        {"correlation_key", cmux::Json(correlation_key)},
        {"created_path", created_path_json(created_path)},
        {"pending_terminal_id",
         cmux::Json(pending.terminal_id.value())},
        {"pending_state", cmux::Json("pending")},
        {"pending_lifecycle", cmux::Json(pending.lifecycle)},
        {"creation_state",
         cmux::Json(creation_state_name(resolution.state))},
        {"creation_recovery",
         cmux::Json(creation_recovery_name(resolution.recovery))},
        {"creation_generation", cmux::Json(*resolution.generation)},
        {"creation_revision",
         cmux::Json(std::to_string(*resolution.revision))},
        {"exit_state", cmux::Json("exited")},
        {"exit_terminal_id", cmux::Json(exited.terminal_id.value())},
        {"exit_lifecycle", cmux::Json("exited")},
        {"exit_kind", cmux::Json("exit")},
        {"exit_code", cmux::Json(std::int64_t{exit_code.code})},
        {"exited_at", cmux::Json(std::to_string(exited.exited_at))},
        {"exit_revision", cmux::Json(std::to_string(exited.revision))},
    });
}

[[nodiscard]] cmux::Json run_live_exit_restart(
    const cmux::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(cmux::Selector<cmux::SessionId>::current());
    const auto correlation_key =
        string_field(request, "expected_correlation_key");
    const auto resolution =
        take(current.resolve_creation(correlation_key));
    if (!resolution.created_path ||
        !resolution.generation ||
        !resolution.revision) {
        throw AdapterError(
            "durable creation resolution omitted required evidence");
    }
    const auto& expected_path = field(request, "expected_created_path");
    auto terminal = client.terminal(opaque_id<cmux::TerminalId>(
        string_field(expected_path, "terminal_id")));
    const auto exit_result = take(terminal.wait_exit(decimal(
        string_field(request, "exit_timeout_ms"))));
    const auto& exited = require_exited(exit_result);
    const auto& exit_code = require_exit_code(exited.outcome);
    return cmux::Json(cmux::Json::Object{
        {"correlation_key", cmux::Json(resolution.correlation_key)},
        {"created_path", created_path_json(*resolution.created_path)},
        {"creation_state",
         cmux::Json(creation_state_name(resolution.state))},
        {"creation_recovery",
         cmux::Json(creation_recovery_name(resolution.recovery))},
        {"creation_generation", cmux::Json(*resolution.generation)},
        {"creation_revision",
         cmux::Json(std::to_string(*resolution.revision))},
        {"exit_state", cmux::Json("exited")},
        {"exit_terminal_id", cmux::Json(exited.terminal_id.value())},
        {"exit_lifecycle", cmux::Json("exited")},
        {"exit_kind", cmux::Json("exit")},
        {"exit_code", cmux::Json(std::int64_t{exit_code.code})},
        {"exited_at", cmux::Json(std::to_string(exited.exited_at))},
        {"exit_revision", cmux::Json(std::to_string(exited.revision))},
    });
}

[[nodiscard]] cmux::Json run_live_restart(const cmux::Json& request) {
    auto client = connect(request, "current");
    auto current =
        client.session(cmux::Selector<cmux::SessionId>::current());
    const auto base = string_field(request, "workspace_name");
    const auto key_prefix = string_field(request, "key_prefix");
    const auto stable_text = string_field(request, "expected_stable_id");
    const auto duplicate_text =
        string_array_field(request, "expected_duplicate_ids");
    if (duplicate_text.size() != 2) {
        throw AdapterError(
            "expected_duplicate_ids must contain exactly two IDs");
    }
    const auto stable_id =
        opaque_id<cmux::WorkspaceId>(stable_text);
    std::vector<cmux::WorkspaceId> duplicate_ids;
    duplicate_ids.reserve(2);
    for (const auto& identifier : duplicate_text) {
        duplicate_ids.push_back(
            opaque_id<cmux::WorkspaceId>(identifier));
    }

    const auto rows = workspace_rows(current);
    const auto same_ids =
        rows.contains(stable_text) &&
        std::ranges::all_of(
            duplicate_text,
            [&rows](const auto& identifier) {
                return rows.contains(identifier);
            });
    const auto stable_name_preserved =
        rows.contains(stable_text) &&
        rows.at(stable_text) == base + "-renamed";
    const auto duplicate_name = base + "-duplicate";
    const auto duplicates_preserved =
        std::ranges::all_of(
            duplicate_text,
            [&rows, &duplicate_name](const auto& identifier) {
                const auto found = rows.find(identifier);
                return found != rows.end() &&
                       found->second == duplicate_name;
            });

    static_cast<void>(take(
        current.workspace(stable_id).close(
            key(key_prefix, "close-stable"))));
    for (std::size_t index = 0; index < duplicate_ids.size(); ++index) {
        static_cast<void>(take(
            current.workspace(duplicate_ids[index]).close(
                key(
                    key_prefix,
                    index == 0 ? "close-a" : "close-b"))));
    }
    const auto remaining = workspace_rows(current);
    const auto disappeared =
        !remaining.contains(stable_text) &&
        std::ranges::none_of(
            duplicate_text,
            [&remaining](const auto& identifier) {
                return remaining.contains(identifier);
            });

    return cmux::Json(cmux::Json::Object{
        {"same_ids", cmux::Json(same_ids)},
        {"stable_name_preserved", cmux::Json(stable_name_preserved)},
        {"duplicates_preserved", cmux::Json(duplicates_preserved)},
        {"closed", cmux::Json(true)},
        {"disappeared", cmux::Json(disappeared)},
    });
}

[[nodiscard]] cmux::Json run_live(const cmux::Json& request) {
    auto client = connect(request, "current");
    const auto available_sessions = take(client.sessions());
    if (available_sessions.empty()) {
        throw AdapterError("session.list omitted an opaque session id");
    }
    auto current_session = client.session(available_sessions.front().id);
    const auto ping = take(current_session.ping());
    const auto pinged = ping.alive;

    const auto name = string_field(request, "workspace_name");
    cmux::CreateWorkspaceOptions create;
    create.name = name;
    create.initial_content = cmux::InitialContent::empty;
    auto created = take(current_session.create_workspace(
        std::move(create),
        take(cmux::MutationOptions::with_key("live-create"))));
    const auto workspace_id = std::visit(
        [](const auto& value) { return value.workspace_id; },
        created.value);
    auto target = client.workspace(workspace_id);
    const auto renamed_result = take(target.rename(
        name + "-renamed",
        take(cmux::MutationOptions::with_key("live-rename"))));
    const auto renamed = renamed_result.value.name == name + "-renamed";
    const auto listed_workspaces = take(current_session.workspaces());
    const auto listed = std::ranges::any_of(
        listed_workspaces,
        [&workspace_id](const auto& item) {
            return item.id == workspace_id;
        });
    static_cast<void>(take(target.close(
        take(cmux::MutationOptions::with_key("live-close")))));
    const auto remaining = take(current_session.workspaces());
    const auto disappeared = std::ranges::none_of(
        remaining,
        [&workspace_id](const auto& item) {
            return item.id == workspace_id;
        });

    return cmux::Json(cmux::Json::Object{
        {"pinged", cmux::Json(pinged)},
        {"created", cmux::Json(true)},
        {"renamed", cmux::Json(renamed)},
        {"listed", cmux::Json(listed)},
        {"closed", cmux::Json(true)},
        {"disappeared", cmux::Json(disappeared)},
    });
}

[[nodiscard]] cmux::Json run(const cmux::Json& request) {
    const auto operation = string_field(request, "op");
    if (operation == "read") {
        return run_read(request);
    }
    if (operation == "mutation-replay") {
        return run_mutation_replay(request);
    }
    if (operation == "mutation-error") {
        return run_mutation_error(request);
    }
    if (operation == "creation-resolve") {
        return run_creation_resolve(request);
    }
    if (operation == "creation-conflict") {
        return run_creation_conflict(request);
    }
    if (operation == "terminal-wait-exit") {
        return run_terminal_wait_exit(request);
    }
    if (operation == "stream-unknown") {
        return run_stream_unknown(request);
    }
    if (operation == "stream-cancel") {
        return run_stream_cancel(request);
    }
    if (operation == "stream-overflow") {
        return run_stream_overflow(request);
    }
    if (operation == "redaction") {
        return run_redaction();
    }
    if (operation == "live-setup") {
        return run_live_setup(request);
    }
    if (operation == "live-creation-exit") {
        return run_live_creation_exit(request);
    }
    if (operation == "live-exit-restart") {
        return run_live_exit_restart(request);
    }
    if (operation == "live-restart") {
        return run_live_restart(request);
    }
    if (operation == "live-flow") {
        return run_live(request);
    }
    throw AdapterError("unknown adapter operation: " + operation);
}

[[nodiscard]] cmux::Json success(
    std::string identifier,
    cmux::Json value) {
    return cmux::Json(cmux::Json::Object{
        {"contract_version", cmux::Json(std::uint64_t{2})},
        {"id", cmux::Json(std::move(identifier))},
        {"ok", cmux::Json(true)},
        {"value", std::move(value)},
    });
}

[[nodiscard]] cmux::Json failure(
    std::string identifier,
    std::string message) {
    return cmux::Json(cmux::Json::Object{
        {"contract_version", cmux::Json(std::uint64_t{2})},
        {"id", cmux::Json(std::move(identifier))},
        {"ok", cmux::Json(false)},
        {"error",
         cmux::Json(cmux::Json::Object{
             {"kind", cmux::Json("adapter")},
             {"message", cmux::Json(std::move(message))},
         })},
    });
}

}  // namespace

int main() {
    std::string input;
    std::getline(std::cin, input);
    std::string identifier;
    cmux::Json response;
    try {
        const auto request = take(cmux::Json::parse(input));
        identifier = string_field(request, "id");
        response = success(identifier, run(request));
    } catch (const std::exception& error) {
        response = failure(identifier, error.what());
    }
    auto encoded = response.encode();
    if (!encoded) {
        std::cerr << describe(encoded.error()) << '\n';
        return 1;
    }
    std::cout << encoded.value() << '\n';
    return 0;
}
