#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <map>
#include <optional>
#include <ostream>
#include <span>
#include <stop_token>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "cmux/json.hpp"
#include "cmux/result.hpp"
#include "cmux/transport.hpp"

namespace cmux {

struct MutationOptions;
struct RawMutationResult;
struct CallOptions;

enum class OperationClass {
    read,
    mutation,
    stream_open,
    connection_control,
};

// The handwritten intent-layer inventory. terminal.create is intentionally
// raw-only: high-level creation uses workspace.run, pane.run, or
// tab.create_terminal.
enum class Operation {
    machine_list,
    machine_get,
    session_list,
    session_open,
    session_get,
    session_snapshot,
    session_creation_resolve,
    session_events,
    session_journal_subscribe,
    session_ping,
    session_shutdown,
    session_reload_config,
    session_terminal_defaults_update,
    client_list,
    client_get,
    client_metadata_update,
    client_sizing_set,
    client_sizing_release,
    client_cell_pixels_set,
    client_detach,
    session_window_title_set,
    session_window_title_clear,
    pairing_request_list,
    pairing_request_resolve,
    request_cancel,
    frontend_projection_get,
    frontend_projection_put,
    workspace_list,
    workspace_get,
    workspace_create,
    workspace_rename,
    workspace_move,
    workspace_focus,
    workspace_close,
    workspace_run,
    workspace_layout_apply,
    screen_list,
    screen_get,
    screen_create,
    screen_rename,
    screen_focus,
    screen_close,
    screen_layout_export,
    screen_layout_undo,
    pane_list,
    pane_get,
    pane_create,
    pane_split,
    pane_rename,
    pane_focus,
    pane_focus_direction,
    pane_neighbor_get,
    pane_swap,
    pane_zoom,
    pane_split_ratio_set,
    pane_viewport_width_set,
    pane_close,
    pane_run,
    tab_list,
    tab_get,
    tab_create_terminal,
    tab_create_browser,
    tab_rename,
    tab_move,
    tab_focus,
    tab_close,
    terminal_list,
    terminal_get,
    terminal_input_write,
    terminal_input_keys,
    terminal_input_mouse,
    terminal_input_focus,
    terminal_screen_read,
    terminal_state_read,
    terminal_history_read,
    terminal_history_clear,
    terminal_wait,
    terminal_wait_exit,
    terminal_copy,
    terminal_process_get,
    terminal_renderer_grant_create,
    terminal_viewer_resize,
    terminal_viewer_release,
    terminal_viewport_scroll,
    terminal_move,
    terminal_project,
    terminal_attach,
    terminal_close,
    browser_list,
    browser_get,
    browser_navigate,
    browser_back,
    browser_forward,
    browser_reload,
    browser_activate,
    browser_input_key,
    browser_input_text,
    browser_input_mouse,
    browser_input_wheel,
    browser_viewer_resize,
    browser_viewer_release,
    browser_attach,
    browser_close,
    notification_list,
    notification_create,
    agent_list,
    agent_report,
    sidebar_view_get,
    sidebar_view_ensure,
    sidebar_view_attach,
    sidebar_view_input,
    sidebar_view_resize,
    sidebar_view_reload,
    stream_cancel,
};

[[nodiscard]] std::string_view operation_name(Operation operation) noexcept;
[[nodiscard]] OperationClass operation_class(Operation operation) noexcept;

namespace detail {

template <std::size_t N>
struct FixedString {
    char value[N]{};

    constexpr FixedString(const char (&text)[N]) {
        for (std::size_t index = 0; index < N; ++index) {
            value[index] = text[index];
        }
    }

    [[nodiscard]] constexpr std::string_view view() const noexcept {
        return {value, N - 1};
    }
};

class ResourceClientState;

[[nodiscard]] Result<Json> resource_read(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    CallOptions call);
[[nodiscard]] Result<Json> resource_control(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    CallOptions call);
[[nodiscard]] Result<RawMutationResult> resource_mutate(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    MutationOptions options,
    CallOptions call);
void complete_structural_route(
    Json::Object& route,
    std::string_view target_scope);

}  // namespace detail

template <detail::FixedString Prefix>
class OpaqueId {
public:
    OpaqueId() = default;

    [[nodiscard]] static Result<OpaqueId> parse(std::string_view value) {
        constexpr auto prefix = Prefix.view();
        if (value.size() != prefix.size() + 32 || !value.starts_with(prefix)) {
            return make_error(
                ErrorCode::invalid_argument,
                "expected " + std::string(prefix) + " followed by 32 lowercase hex digits");
        }
        for (const char byte : value.substr(prefix.size())) {
            if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
                return make_error(
                    ErrorCode::invalid_argument,
                    "opaque IDs require lowercase hexadecimal digits");
            }
        }
        return OpaqueId(std::string(value));
    }

    [[nodiscard]] const std::string& value() const noexcept { return value_; }
    [[nodiscard]] bool empty() const noexcept { return value_.empty(); }
    [[nodiscard]] static constexpr std::string_view prefix() noexcept {
        return Prefix.view();
    }

    friend bool operator==(const OpaqueId&, const OpaqueId&) = default;
    friend auto operator<=>(const OpaqueId&, const OpaqueId&) = default;

private:
    explicit OpaqueId(std::string value) : value_(std::move(value)) {}
    std::string value_;
};

using MachineId = OpaqueId<"machine_">;
using SessionId = OpaqueId<"session_">;
using WorkspaceId = OpaqueId<"ws_">;
using ScreenId = OpaqueId<"screen_">;
using PaneId = OpaqueId<"pane_">;
using TabId = OpaqueId<"tab_">;
using TerminalId = OpaqueId<"term_">;
using BrowserId = OpaqueId<"browser_">;
using ConnectedClientId = OpaqueId<"client_">;
using SplitId = OpaqueId<"split_">;
using NotificationId = OpaqueId<"notification_">;
using AgentId = OpaqueId<"agent_">;
using StreamId = OpaqueId<"stream_">;
using FrontendProjectionId = OpaqueId<"projection_">;
using PairingRequestId = OpaqueId<"pairing_">;
using SidebarViewId = OpaqueId<"sidebar_view_">;

template <typename Id>
class Selector {
public:
    enum class Kind {
        id,
        current,
        name,
    };

    [[nodiscard]] static Selector by_id(Id id) {
        auto value = id.value();
        return Selector(Kind::id, std::move(value), std::move(id));
    }
    [[nodiscard]] static Selector current() {
        return Selector(Kind::current, "current", std::nullopt);
    }
    [[nodiscard]] static Selector exact_name(std::string name) {
        return Selector(Kind::name, std::move(name), std::nullopt);
    }

    [[nodiscard]] Kind kind() const noexcept { return kind_; }
    [[nodiscard]] const std::string& value() const noexcept { return value_; }
    [[nodiscard]] const std::optional<Id>& selected_id() const noexcept {
        return selected_id_;
    }

    // Names are always explicitly tagged. This avoids ambiguity with
    // "current", opaque-ID-shaped names, and future selector syntax.
    [[nodiscard]] std::string wire() const {
        return kind_ == Kind::name ? "name:" + value_ : value_;
    }

private:
    Selector(Kind kind, std::string value, std::optional<Id> selected_id)
        : kind_(kind),
          value_(std::move(value)),
          selected_id_(std::move(selected_id)) {}

    Kind kind_;
    std::string value_;
    std::optional<Id> selected_id_;
};

struct MutationOptions {
    [[nodiscard]] static Result<MutationOptions> with_key(std::string key);
    [[nodiscard]] static MutationOptions unique();

    [[nodiscard]] const std::string& idempotency_key() const noexcept {
        return idempotency_key_;
    }
    [[nodiscard]] std::optional<std::uint64_t> expected_revision() const noexcept {
        return expected_revision_;
    }
    [[nodiscard]] MutationOptions expecting(std::uint64_t revision) const {
        auto copy = *this;
        copy.expected_revision_ = revision;
        return copy;
    }

private:
    explicit MutationOptions(std::string key)
        : idempotency_key_(std::move(key)) {}
    std::string idempotency_key_;
    std::optional<std::uint64_t> expected_revision_;
};

class RunCommand {
public:
    [[nodiscard]] static Result<RunCommand> exact(std::vector<std::string> argv);
    [[nodiscard]] static Result<RunCommand> shell(std::string script);
    [[nodiscard]] static Result<RunCommand> shell_with_executable(
        std::string executable,
        std::string script);

    [[nodiscard]] const std::vector<std::string>& argv() const noexcept {
        return argv_;
    }
    [[nodiscard]] const std::optional<std::string>& shell_script() const noexcept {
        return shell_script_;
    }
    void encode_into(Json::Object& params) const;

private:
    explicit RunCommand(std::vector<std::string> argv)
        : argv_(std::move(argv)) {}
    explicit RunCommand(std::string script)
        : shell_script_(std::move(script)) {}
    std::vector<std::string> argv_;
    std::optional<std::string> shell_script_;
};

enum class InitialContent {
    terminal,
    empty,
};

struct CreateWorkspaceOptions {
    std::optional<std::string> name;
    InitialContent initial_content = InitialContent::terminal;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct RunOptions {
    explicit RunOptions(RunCommand command_value)
        : command(std::move(command_value)) {}

    RunCommand command;
    std::optional<std::string> cwd;
    std::optional<std::string> name;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreateScreenOptions {
    std::optional<std::string> name;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreatePaneOptions {
    std::optional<std::string> cwd;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

enum class PaneDirection {
    left,
    right,
    up,
    down,
};

struct SplitPaneOptions {
    explicit SplitPaneOptions(PaneDirection direction_value)
        : direction(direction_value) {}

    PaneDirection direction;
    std::optional<double> ratio;
    std::optional<std::string> cwd;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;
    std::optional<std::string> correlation_key;
    std::optional<double> viewport_width;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreateTerminalTabOptions {
    std::optional<std::string> cwd;
    std::optional<std::string> name;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreateBrowserTabOptions {
    explicit CreateBrowserTabOptions(std::string initial_url)
        : url(std::move(initial_url)) {}

    std::string url;
    std::optional<std::string> name;
    std::optional<std::uint32_t> width_px;
    std::optional<std::uint32_t> height_px;
    std::optional<std::string> correlation_key;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct UndoLayoutOptions {
    bool confirm_close = false;
    std::optional<std::string> confirmation_token;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct TerminalHistoryOptions {
    std::optional<std::uint64_t> before;
    std::optional<std::uint32_t> limit;
    std::optional<bool> styled;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct TerminalAttachOptions {
    std::optional<std::uint16_t> cols;
    std::optional<std::uint16_t> rows;
    bool read_only = false;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct Cursor {
    std::string generation;
    std::uint64_t revision = 0;
};

enum class JournalStart { tail, beginning };
enum class JournalClass { state, observation, effect, checkpoint };
enum class JournalReplayPolicy { required, advisory, never };
enum class JournalSensitivity { public_, metadata, sensitive, secret };
enum class JournalRegexField { kind, subjects, payload, record, terminal_output };

struct JournalSubjectFilter {
    std::optional<std::string> kind;
    std::optional<std::string> id;
};

struct JournalRegexFilter {
    std::string pattern;
    JournalRegexField field = JournalRegexField::record;
    bool case_sensitive = true;
};

struct JournalFilter {
    std::vector<std::string> kinds;
    std::vector<JournalClass> classes;
    std::vector<JournalSubjectFilter> subjects;
    std::optional<JournalSensitivity> max_sensitivity;
    std::optional<JournalRegexFilter> regex;
};

struct SessionJournalOptions {
    std::optional<Cursor> cursor;
    std::optional<JournalStart> start;
    std::optional<bool> follow;
    JournalFilter filter;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct JournalProducer {
    std::string kind;
    std::string id;
};

struct JournalAuthority {
    std::string principal_id;
    std::string lease_id;
    std::string generation;
    std::string role;
};

struct JournalSubject {
    std::string kind;
    std::string id;
};

struct SessionJournalRecord {
    std::uint64_t sequence = 0;
    std::string event_id;
    std::uint32_t schema_version = 0;
    std::string kind;
    JournalClass journal_class = JournalClass::state;
    JournalReplayPolicy replay = JournalReplayPolicy::required;
    std::uint64_t occurred_at_ms = 0;
    std::uint64_t committed_at_ms = 0;
    JournalProducer producer;
    std::optional<JournalAuthority> authority;
    std::optional<std::string> causation_id;
    std::optional<std::string> correlation_id;
    std::uint16_t causation_depth = 0;
    std::vector<JournalSubject> subjects;
    JournalSensitivity sensitivity = JournalSensitivity::sensitive;
    Json payload;
    std::optional<std::uint64_t> resource_revision;
    std::optional<std::uint64_t> previous_resource_revision;
};

struct ConfirmationRequiredDetails {
    std::string confirmation_token;
    std::uint64_t revision = 0;
    std::vector<PaneId> closes_panes;
};

[[nodiscard]] Result<ConfirmationRequiredDetails>
decode_confirmation_required_details(const Error& error);

struct CreatedWorkspaceOnly {
    WorkspaceId workspace_id;
};

struct CreatedTerminalPath {
    WorkspaceId workspace_id;
    ScreenId screen_id;
    PaneId pane_id;
    TabId tab_id;
    TerminalId terminal_id;
};

struct CreatedBrowserPath {
    WorkspaceId workspace_id;
    ScreenId screen_id;
    PaneId pane_id;
    TabId tab_id;
    BrowserId browser_id;
};

using CreatedPath = std::variant<
    CreatedWorkspaceOnly,
    CreatedTerminalPath,
    CreatedBrowserPath>;

struct RawMutationResult {
    Json value;
    std::string generation;
    std::uint64_t revision = 0;
    bool replayed = false;
};

template <typename T>
struct MutationResult {
    T value;
    std::string generation;
    std::uint64_t revision = 0;
    bool replayed = false;
};

class SensitiveString {
public:
    explicit SensitiveString(std::string value)
        : value_(std::move(value)) {}

    [[nodiscard]] const std::string& reveal() const noexcept { return value_; }
    friend bool operator==(const SensitiveString&, const SensitiveString&) =
        default;
    friend std::ostream& operator<<(
        std::ostream& stream,
        const SensitiveString&) {
        return stream << "[REDACTED]";
    }

private:
    std::string value_;
};

struct RendererGrant {
    std::string endpoint;
    TerminalId terminal_id;
    SensitiveString token;
    std::vector<std::string> rights;
    std::uint32_t ttl_ms = 0;

    friend std::ostream& operator<<(
        std::ostream& stream,
        const RendererGrant&) {
        return stream << "RendererGrant{token=[REDACTED]}";
    }
};

// JsonValue appears only where the catalog explicitly accepts arbitrary JSON.
using JsonValue = Json;

enum class LayoutDirection {
    horizontal,
    vertical,
};

struct LayoutNode;

struct LayoutLeaf {
    PaneId pane_id;
    std::vector<TabId> tab_ids;
    std::optional<TabId> active_tab_id;
};

struct LayoutSplit {
    SplitId split_id;
    LayoutDirection direction = LayoutDirection::horizontal;
    double ratio = 0.5;
    std::shared_ptr<const LayoutNode> first;
    std::shared_ptr<const LayoutNode> second;
};

struct LayoutStack {
    std::vector<PaneId> pane_ids;
    PaneId expanded_pane_id;
};

struct LayoutColumn {
    SplitId column_id;
    double width = 1.0;
    std::shared_ptr<const LayoutNode> root;
};

struct LayoutViewport {
    double base_width = 1.0;
    std::vector<LayoutColumn> columns;
};

struct LayoutNode {
    std::variant<LayoutLeaf, LayoutSplit, LayoutStack, LayoutViewport> value;
};

struct LayoutDocument {
    std::uint32_t version = 0;
    ScreenId screen_id;
    PaneId active_pane_id;
    std::optional<PaneId> zoomed_pane_id;
    LayoutNode root;
    Json::Object extra;
};

struct Size {
    std::uint16_t cols = 0;
    std::uint16_t rows = 0;
};

struct PixelSize {
    std::uint32_t width_px = 0;
    std::uint32_t height_px = 0;
};

enum class MachineOrigin {
    local,
};

enum class MachineStatus {
    running,
    connecting,
    sleeping,
    stopped,
    unavailable,
};

struct MachineSnapshot {
    MachineId id;
    std::string name;
    MachineOrigin origin = MachineOrigin::local;
    MachineStatus status = MachineStatus::running;
    bool connectable = false;
    bool deleted = false;
    bool recoverable = false;
    Json::Object extra;
};

struct SessionSnapshot {
    SessionId id;
    MachineId machine_id;
    std::optional<std::string> name;
    std::string generation;
    std::uint64_t revision = 0;
    bool connected = false;
    Json::Object extra;
};

struct WorkspaceSnapshot {
    WorkspaceId id;
    SessionId session_id;
    std::string name;
    std::uint32_t index = 0;
    bool focused = false;
    Json::Object extra;
};

struct ScreenSnapshot {
    ScreenId id;
    WorkspaceId workspace_id;
    std::optional<std::string> name;
    std::uint32_t index = 0;
    bool focused = false;
    LayoutDocument layout;
    Json::Object extra;
};

struct PaneSnapshot {
    PaneId id;
    ScreenId screen_id;
    std::optional<std::string> name;
    bool focused = false;
    bool zoomed = false;
    Json::Object extra;
};

using TabContentId = std::variant<TerminalId, BrowserId>;

struct TabSnapshot {
    TabId id;
    PaneId pane_id;
    std::optional<std::string> name;
    std::uint32_t index = 0;
    bool focused = false;
    TabContentId content_id;
    Json::Object extra;
};

enum class TerminalLifecycle {
    launching,
    running,
    exited,
};

struct TerminalExitCode {
    std::int32_t code = 0;
};

struct TerminalExitSignal {
    std::int32_t signal = 0;
    bool core_dumped = false;
};

struct TerminalExitUnknown {
    std::string reason;
};

using TerminalExitOutcome = std::variant<
    TerminalExitCode,
    TerminalExitSignal,
    TerminalExitUnknown>;

struct TerminalExit {
    TerminalExitOutcome outcome;
    std::uint64_t exited_at = 0;
    std::uint64_t revision = 0;
};

struct TerminalSnapshot {
    TerminalId id;
    std::optional<TabId> tab_id;
    std::vector<TabId> tab_ids;
    std::string title;
    std::optional<std::string> cwd;
    std::uint16_t cols = 0;
    std::uint16_t rows = 0;
    bool running = false;
    TerminalLifecycle lifecycle = TerminalLifecycle::launching;
    std::optional<TerminalExit> exit;
    Json::Object extra;
};

enum class BrowserSource {
    external,
    launched,
};

enum class BrowserStatus {
    starting,
    live,
    failed,
};

struct BrowserSnapshot {
    BrowserId id;
    TabId tab_id;
    std::string url;
    std::string title;
    bool loading = false;
    BrowserSource source = BrowserSource::external;
    BrowserStatus status = BrowserStatus::starting;
    std::optional<std::string> error;
    bool frames_stalled = false;
    Size size;
    Json::Object extra;
};

struct ClientTerminalSize {
    TerminalId terminal_id;
    std::optional<std::uint16_t> cols;
    std::optional<std::uint16_t> rows;
    bool participating = false;
};

enum class ClientTransport {
    unix_socket,
    websocket,
};

struct ClientSnapshot {
    ConnectedClientId id;
    SessionId session_id;
    std::optional<std::string> name;
    std::optional<std::string> client_kind;
    ClientTransport transport = ClientTransport::unix_socket;
    std::uint64_t connected_seconds = 0;
    std::vector<TerminalId> attached_terminal_ids;
    std::vector<ClientTerminalSize> sizes;
    bool self = false;
    Json::Object extra;
};

enum class NotificationLevel {
    info,
    warning,
    error,
};

struct NotificationCreateOptions {
    NotificationCreateOptions(
        std::string title_value,
        std::string body_value)
        : title(std::move(title_value)),
          body(std::move(body_value)) {}

    std::string title;
    std::string body;
    std::optional<NotificationLevel> level;
    std::optional<TerminalId> terminal_id;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct NotificationSnapshot {
    NotificationId id;
    SessionId session_id;
    std::string title;
    std::string body;
    NotificationLevel level = NotificationLevel::info;
    std::optional<TerminalId> terminal_id;
    std::uint64_t created_at_ms = 0;
    bool unread = false;
    Json::Object extra;
};

enum class AgentState {
    working,
    blocked,
    idle,
    done,
    unknown,
};

enum class AgentSource {
    hook,
    socket,
    detected,
};

enum class AgentReportSource {
    hook,
    socket,
};

struct AgentReportOptions {
    AgentReportOptions(
        TerminalId terminal_id_value,
        AgentState state_value,
        AgentReportSource source_value)
        : terminal_id(std::move(terminal_id_value)),
          state(state_value),
          source(source_value) {}

    TerminalId terminal_id;
    AgentState state;
    AgentReportSource source;
    std::optional<std::string> source_session;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct AgentSnapshot {
    AgentId id;
    SessionId session_id;
    TerminalId terminal_id;
    AgentState state = AgentState::unknown;
    AgentSource source = AgentSource::detected;
    std::uint64_t updated_at_ms = 0;
    std::optional<std::string> source_session;
    Json::Object extra;
};

enum class PairingStatus {
    pending,
    accepted,
    rejected,
};

struct PairingRequestSnapshot {
    PairingRequestId id;
    SessionId session_id;
    std::string peer;
    SensitiveString code{""};
    std::uint64_t expires_in_seconds = 0;
    PairingStatus status = PairingStatus::pending;
    Json::Object extra;
};

struct FrontendProjectionSnapshot {
    FrontendProjectionId id;
    SessionId session_id;
    std::string frontend_id;
    std::string window_id;
    std::string generation;
    JsonValue projection;
    std::uint64_t projection_revision = 0;
    Json::Object extra;
};

struct ProjectionPutOptions {
    std::string frontend_id;
    std::string window_id;
    std::string generation;
    JsonValue projection;
    std::optional<std::uint64_t> expected_projection_revision;
};

struct SidebarViewSnapshot {
    SidebarViewId id;
    SessionId session_id;
    std::uint16_t cols = 0;
    std::uint16_t rows = 0;
    bool running = false;
    Json::Object extra;
};

struct ResourceSnapshot {
    MachineSnapshot machine;
    SessionSnapshot session;
    std::vector<WorkspaceSnapshot> workspaces;
    std::vector<ScreenSnapshot> screens;
    std::vector<PaneSnapshot> panes;
    std::vector<TabSnapshot> tabs;
    std::vector<TerminalSnapshot> terminals;
    std::vector<BrowserSnapshot> browsers;
    std::vector<ClientSnapshot> clients;
    std::vector<NotificationSnapshot> notifications;
    std::vector<AgentSnapshot> agents;
    std::vector<FrontendProjectionSnapshot> frontend_projections;
    std::vector<SidebarViewSnapshot> sidebar_views;
    Cursor cursor;
    Json::Object extra;
};

using ResourceChangeId = std::variant<
    MachineId,
    SessionId,
    WorkspaceId,
    ScreenId,
    PaneId,
    TabId,
    TerminalId,
    BrowserId,
    ConnectedClientId,
    NotificationId,
    AgentId,
    PairingRequestId,
    FrontendProjectionId,
    SidebarViewId>;

using ResourceEntitySnapshot = std::variant<
    MachineSnapshot,
    SessionSnapshot,
    WorkspaceSnapshot,
    ScreenSnapshot,
    PaneSnapshot,
    TabSnapshot,
    TerminalSnapshot,
    BrowserSnapshot,
    ClientSnapshot,
    NotificationSnapshot,
    AgentSnapshot,
    PairingRequestSnapshot,
    FrontendProjectionSnapshot,
    SidebarViewSnapshot>;

enum class ResourceKind {
    machine,
    session,
    workspace,
    screen,
    pane,
    tab,
    terminal,
    browser,
    client,
    notification,
    agent,
    pairing_request,
    frontend_projection,
    sidebar_view,
};

struct ResourceUpsert {
    std::uint32_t sequence = 0;
    ResourceKind resource = ResourceKind::machine;
    ResourceChangeId id;
    ResourceEntitySnapshot value;
};

struct ResourceDelete {
    std::uint32_t sequence = 0;
    ResourceKind resource = ResourceKind::machine;
    ResourceChangeId id;
};

struct Unknown {
    std::string kind;
    Json raw;
};

using ResourceChange = std::variant<ResourceUpsert, ResourceDelete, Unknown>;

enum class RenderCursorStyle {
    block,
    underline,
    bar,
};

enum class RenderUnderline {
    single,
    double_line,
    curly,
    dotted,
    dashed,
};

struct RenderCursor {
    std::uint16_t x = 0;
    std::uint16_t y = 0;
    RenderCursorStyle style = RenderCursorStyle::block;
    bool blink = false;
    bool visible = false;
    std::optional<std::string> color;
};

struct RenderRun {
    std::string text;
    std::optional<std::string> foreground;
    std::optional<std::string> background;
    std::uint32_t attributes = 0;
    std::optional<RenderUnderline> underline;
    std::optional<std::uint16_t> width_hint;
};

struct RenderRow {
    std::uint16_t row = 0;
    std::vector<RenderRun> runs;
};

struct RenderSnapshot {
    Size size;
    RenderCursor cursor;
    std::string default_fg;
    std::string default_bg;
    std::uint32_t scrollback_rows = 0;
    std::vector<RenderRow> rows;
};

struct RenderPatch {
    RenderCursor cursor;
    bool full_reset = false;
    std::optional<Size> size;
    std::optional<std::string> default_fg;
    std::optional<std::string> default_bg;
    std::optional<std::uint32_t> scrollback_rows;
    std::vector<RenderRow> rows;
};

struct RenderScroll {
    std::uint64_t offset = 0;
    bool at_bottom = false;
};

struct EmptyResult {};

struct PingResult {
    bool alive = false;
    Cursor cursor;
};

struct ShutdownResult {
    bool accepted = false;
};

struct ReloadConfigResult {
    bool reloaded = false;
    std::vector<std::string> warnings;
};

template <typename T>
struct NullableField {
    bool present = false;
    std::optional<T> value;
};

struct TerminalDefaultsSnapshot {
    NullableField<std::string> foreground;
    NullableField<std::string> background;
    NullableField<std::string> cursor;
    NullableField<std::string> selection_background;
    NullableField<std::string> selection_foreground;
    NullableField<std::string> cursor_style;
    NullableField<bool> cursor_blink;
    std::optional<std::map<std::string, std::string, std::less<>>> palette;
};

struct PairingResolutionResult {
    PairingRequestSnapshot pairing_request;
};

struct PaneNeighborResult {
    std::optional<PaneSnapshot> pane;
};

struct TerminalScreenResult {
    std::string text;
    std::uint16_t cols = 0;
    std::uint16_t rows = 0;
    std::uint16_t cursor_row = 0;
    std::uint16_t cursor_col = 0;
    bool cursor_visible = false;
    Json::Object extra;
};

struct TerminalStateResult {
    std::vector<std::byte> state;
    std::uint16_t cols = 0;
    std::uint16_t rows = 0;
};

struct TerminalHistoryResult {
    std::uint64_t start = 0;
    std::optional<std::uint64_t> next;
    std::vector<RenderRow> rows;
};

struct TerminalWaitResult {
    bool matched = false;
    std::string text;
};

enum class TerminalCopyMode {
    screen,
    selection,
    scrollback,
};

struct TerminalCopyResult {
    TerminalCopyMode mode = TerminalCopyMode::screen;
    std::string text;
};

struct ProcessInfoResult {
    std::uint32_t pid = 0;
    std::optional<std::string> executable;
    std::vector<std::string> argv;
    std::optional<std::string> cwd;
    std::vector<std::uint32_t> children;
};

struct CellPixelsResult {
    std::uint32_t width_px = 0;
    std::uint32_t height_px = 0;
    std::vector<TerminalId> resized_terminals;
    std::map<std::string, std::string, std::less<>> failures;
};

struct ViewerResizeResult {
    bool accepted = false;
    Size size;
    enum class Outcome {
        applied,
        passive,
        superseded,
    } outcome = Outcome::passive;
};

struct BrowserViewerResizeResult {
    bool accepted = false;
    PixelSize size;
    ViewerResizeResult::Outcome outcome = ViewerResizeResult::Outcome::passive;
};

struct ViewerReleaseResult {
    ViewerResizeResult::Outcome outcome = ViewerResizeResult::Outcome::passive;
};

enum class CreationState {
    pending,
    created,
    not_applied,
    indeterminate,
};

enum class CreationRecovery {
    retry_same_idempotency_key,
    retry_new_idempotency_key,
    wait,
    none,
    do_not_retry,
};

struct CreationResolution {
    std::string correlation_key;
    CreationState state = CreationState::pending;
    CreationRecovery recovery = CreationRecovery::wait;
    std::optional<std::string> operation;
    std::optional<std::string> idempotency_key;
    std::optional<CreatedPath> created_path;
    std::optional<std::string> generation;
    std::optional<std::uint64_t> revision;
};

struct TerminalWaitExitPending {
    TerminalId terminal_id;
    std::string lifecycle;
    std::uint64_t revision = 0;
};

struct TerminalWaitExitExited {
    TerminalId terminal_id;
    TerminalExitOutcome outcome;
    std::uint64_t exited_at = 0;
    std::uint64_t revision = 0;
};

using TerminalWaitExitResult = std::variant<
    TerminalWaitExitPending,
    TerminalWaitExitExited>;

struct MutationOutcomeUncertain {
    Operation operation = Operation::machine_list;
    std::string idempotency_key;
};

struct CallOptions {
    std::optional<std::chrono::steady_clock::time_point> deadline;
    std::stop_token cancel;

    [[nodiscard]] static CallOptions with_timeout(Timeout timeout) {
        return {
            std::chrono::steady_clock::now() + timeout,
            {},
        };
    }
};

namespace detail {

template <typename T>
[[nodiscard]] Result<T> decode_value(const Json& value);

#define CMUX_DECLARE_TYPED_DECODER(type)            \
    template <>                                     \
    [[nodiscard]] Result<type> decode_value<type>(  \
        const Json& value)

CMUX_DECLARE_TYPED_DECODER(CreatedPath);
CMUX_DECLARE_TYPED_DECODER(CreatedTerminalPath);
CMUX_DECLARE_TYPED_DECODER(CreatedBrowserPath);
CMUX_DECLARE_TYPED_DECODER(EmptyResult);
CMUX_DECLARE_TYPED_DECODER(ConfirmationRequiredDetails);
CMUX_DECLARE_TYPED_DECODER(MachineSnapshot);
CMUX_DECLARE_TYPED_DECODER(SessionSnapshot);
CMUX_DECLARE_TYPED_DECODER(WorkspaceSnapshot);
CMUX_DECLARE_TYPED_DECODER(ScreenSnapshot);
CMUX_DECLARE_TYPED_DECODER(PaneSnapshot);
CMUX_DECLARE_TYPED_DECODER(TabSnapshot);
CMUX_DECLARE_TYPED_DECODER(TerminalSnapshot);
CMUX_DECLARE_TYPED_DECODER(BrowserSnapshot);
CMUX_DECLARE_TYPED_DECODER(ClientSnapshot);
CMUX_DECLARE_TYPED_DECODER(NotificationSnapshot);
CMUX_DECLARE_TYPED_DECODER(AgentSnapshot);
CMUX_DECLARE_TYPED_DECODER(PairingRequestSnapshot);
CMUX_DECLARE_TYPED_DECODER(FrontendProjectionSnapshot);
CMUX_DECLARE_TYPED_DECODER(SidebarViewSnapshot);
CMUX_DECLARE_TYPED_DECODER(ResourceSnapshot);
CMUX_DECLARE_TYPED_DECODER(LayoutDocument);
CMUX_DECLARE_TYPED_DECODER(ResourceChange);
CMUX_DECLARE_TYPED_DECODER(PingResult);
CMUX_DECLARE_TYPED_DECODER(ShutdownResult);
CMUX_DECLARE_TYPED_DECODER(ReloadConfigResult);
CMUX_DECLARE_TYPED_DECODER(TerminalDefaultsSnapshot);
CMUX_DECLARE_TYPED_DECODER(PairingResolutionResult);
CMUX_DECLARE_TYPED_DECODER(PaneNeighborResult);
CMUX_DECLARE_TYPED_DECODER(TerminalScreenResult);
CMUX_DECLARE_TYPED_DECODER(TerminalStateResult);
CMUX_DECLARE_TYPED_DECODER(TerminalHistoryResult);
CMUX_DECLARE_TYPED_DECODER(TerminalWaitResult);
CMUX_DECLARE_TYPED_DECODER(TerminalWaitExitResult);
CMUX_DECLARE_TYPED_DECODER(TerminalCopyResult);
CMUX_DECLARE_TYPED_DECODER(ProcessInfoResult);
CMUX_DECLARE_TYPED_DECODER(RendererGrant);
CMUX_DECLARE_TYPED_DECODER(CellPixelsResult);
CMUX_DECLARE_TYPED_DECODER(ViewerResizeResult);
CMUX_DECLARE_TYPED_DECODER(BrowserViewerResizeResult);
CMUX_DECLARE_TYPED_DECODER(ViewerReleaseResult);
CMUX_DECLARE_TYPED_DECODER(CreationResolution);
CMUX_DECLARE_TYPED_DECODER(JsonValue);

#undef CMUX_DECLARE_TYPED_DECODER

template <typename T>
[[nodiscard]] Result<std::vector<T>> decode_list(const Json& value) {
    auto values = value.as_array();
    if (!values) {
        return make_error(ErrorCode::decode, "result must be an array");
    }
    std::vector<T> decoded;
    decoded.reserve(values.value()->size());
    for (const auto& item : *values.value()) {
        auto parsed = decode_value<T>(item);
        if (!parsed) {
            return std::move(parsed).error();
        }
        decoded.push_back(std::move(parsed).value());
    }
    return decoded;
}

template <typename T>
[[nodiscard]] Result<MutationResult<T>> typed_mutation(
    Result<RawMutationResult> raw) {
    if (!raw) {
        return std::move(raw).error();
    }
    auto value = decode_value<T>(raw.value().value);
    if (!value) {
        return std::move(value).error();
    }
    return MutationResult<T>{
        std::move(value).value(),
        std::move(raw.value().generation),
        raw.value().revision,
        raw.value().replayed,
    };
}

template <typename T>
struct IsVector : std::false_type {};

template <typename T, typename Allocator>
struct IsVector<std::vector<T, Allocator>> : std::true_type {
    using value_type = T;
};

class ResourceReadResult {
public:
    explicit ResourceReadResult(Result<Json> result)
        : result_(std::move(result)) {}

    template <typename T>
    operator Result<T>() && {
        if (!result_) {
            return std::move(result_).error();
        }
        if constexpr (IsVector<T>::value) {
            return decode_list<typename IsVector<T>::value_type>(
                result_.value());
        } else {
            return decode_value<T>(result_.value());
        }
    }

private:
    Result<Json> result_;
};

class ResourceMutationResult {
public:
    explicit ResourceMutationResult(Result<RawMutationResult> result)
        : result_(std::move(result)) {}

    operator Result<RawMutationResult>() && {
        return std::move(result_);
    }

    template <typename T>
    operator Result<MutationResult<T>>() && {
        return typed_mutation<T>(std::move(result_));
    }

private:
    Result<RawMutationResult> result_;
};

}  // namespace detail

struct ClientOptions {
    std::string session{"main"};
    std::string socket_path;
    std::string machine_selector{"current"};
    std::string session_selector{"current"};
    Timeout timeout{std::chrono::seconds(10)};
    TransportLimits transport_limits{};
    JsonLimits json_limits{};
    TransportFactory transport_factory;
    TransportFactory stream_transport_factory;
};

struct RawStreamItem {
    std::uint64_t sequence = 0;
    std::optional<Cursor> cursor;
    Json value;
};

enum class StreamEndReason {
    completed,
    canceled,
    closed,
    gap,
    error,
};

struct StreamEnd {
    StreamEndReason reason = StreamEndReason::closed;
    std::optional<Cursor> cursor;
    std::optional<std::string> recovery;
    std::optional<Error> error;
};

class ResourceStream {
public:
    ResourceStream(const ResourceStream&) = delete;
    ResourceStream& operator=(const ResourceStream&) = delete;
    ResourceStream(ResourceStream&&) noexcept;
    ResourceStream& operator=(ResourceStream&&) noexcept;
    ~ResourceStream();

    [[nodiscard]] const StreamId& id() const noexcept;
    [[nodiscard]] const std::optional<std::string>& attachment_lease() const noexcept;
    // Waits until an item, stream end, transport failure, or cancellation.
    // Request and stream-open deadlines do not become idle deadlines.
    [[nodiscard]] Result<std::optional<RawStreamItem>> next();
    // Bounds one wait without closing the stream when the wait times out.
    [[nodiscard]] Result<std::optional<RawStreamItem>> next(Timeout timeout);
    [[nodiscard]] Result<std::optional<RawStreamItem>> poll(Timeout timeout) {
        return next(timeout);
    }
    [[nodiscard]] Result<Json> connection_control(
        Operation operation,
        Json::Object params = {});
    [[nodiscard]] Result<StreamEnd> cancel();
    [[nodiscard]] bool closed() const noexcept;
    [[nodiscard]] const std::optional<StreamEnd>& end() const noexcept;

private:
    struct Impl;
public:
    explicit ResourceStream(std::unique_ptr<Impl> impl);
private:
    std::unique_ptr<Impl> impl_;
    friend class Client;
    friend class detail::ResourceClientState;
};

namespace detail {

[[nodiscard]] Result<ResourceStream> resource_open_stream(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    CallOptions call);

}  // namespace detail

enum class SessionResetReason {
    initial,
    generation_changed,
    cursor_expired,
};

struct SessionSnapshotEvent {
    Cursor cursor;
    std::optional<SessionResetReason> reset_reason;
    ResourceSnapshot snapshot;
};

struct SessionDeltaEvent {
    Cursor cursor;
    std::uint64_t previous_revision = 0;
    std::uint64_t revision = 0;
    std::vector<ResourceChange> changes;
};

// Open unions retain the discriminator and complete object so newer servers
// remain observable without turning malformed known variants into Unknown.
using SessionEvent = std::variant<
    SessionSnapshotEvent,
    SessionDeltaEvent,
    Unknown>;

struct TerminalAttachSnapshot {
    TerminalId terminal_id;
    RenderSnapshot render;
};

struct TerminalAttachPatch {
    TerminalId terminal_id;
    RenderPatch render;
};

struct TerminalAttachScroll {
    TerminalId terminal_id;
    RenderScroll scroll;
};

using TerminalAttachmentItem = std::variant<
    TerminalAttachSnapshot,
    TerminalAttachPatch,
    TerminalAttachScroll,
    Unknown>;

struct BrowserAttachSnapshot {
    BrowserSnapshot browser;
    PixelSize size;
};

struct BrowserAttachFrame {
    std::string mime_type;
    std::vector<std::byte> data;
    std::uint32_t width_px = 0;
    std::uint32_t height_px = 0;
    std::optional<std::uint64_t> pointer_frame_seq;
};

struct BrowserAttachState {
    std::string url;
    std::string title;
    bool loading = false;
};

using BrowserAttachmentItem = std::variant<
    BrowserAttachSnapshot,
    BrowserAttachFrame,
    BrowserAttachState,
    Unknown>;

struct SidebarAttachSnapshot {
    SidebarViewSnapshot sidebar_view;
    RenderSnapshot render;
};

struct SidebarAttachPatch {
    SidebarViewId sidebar_view_id;
    RenderPatch render;
};

struct SidebarAttachScroll {
    SidebarViewId sidebar_view_id;
    RenderScroll scroll;
};

using SidebarViewItem = std::variant<
    SidebarAttachSnapshot,
    SidebarAttachPatch,
    SidebarAttachScroll,
    Unknown>;

template <typename T>
struct TypedStreamItem {
    std::uint64_t sequence = 0;
    std::optional<Cursor> cursor;
    T value;
};

namespace detail {

[[nodiscard]] Result<SessionEvent> decode_session_event(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor);
[[nodiscard]] Result<SessionJournalRecord> decode_session_journal_record(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor);
[[nodiscard]] Result<TerminalAttachmentItem> decode_terminal_attachment(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor);
[[nodiscard]] Result<BrowserAttachmentItem> decode_browser_attachment(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor);
[[nodiscard]] Result<SidebarViewItem> decode_sidebar_view_item(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor);
[[nodiscard]] Result<ViewerResizeResult> decode_viewer_resize(
    const Json& value);
[[nodiscard]] Result<BrowserViewerResizeResult> decode_browser_viewer_resize(
    const Json& value);
[[nodiscard]] Result<ViewerReleaseResult> decode_viewer_release(
    const Json& value);
[[nodiscard]] Result<EmptyResult> decode_empty_result(const Json& value);

template <typename T>
[[nodiscard]] Result<T> decode_stream_domain(
    const Json& value,
    const std::optional<Cursor>& envelope_cursor) {
    if constexpr (std::same_as<T, SessionEvent>) {
        return decode_session_event(value, envelope_cursor);
    } else if constexpr (std::same_as<T, SessionJournalRecord>) {
        return decode_session_journal_record(value, envelope_cursor);
    } else if constexpr (std::same_as<T, TerminalAttachmentItem>) {
        return decode_terminal_attachment(value, envelope_cursor);
    } else if constexpr (std::same_as<T, BrowserAttachmentItem>) {
        return decode_browser_attachment(value, envelope_cursor);
    } else if constexpr (std::same_as<T, SidebarViewItem>) {
        return decode_sidebar_view_item(value, envelope_cursor);
    }
}

}  // namespace detail

template <typename T>
class TypedResourceStream {
public:
    TypedResourceStream(const TypedResourceStream&) = delete;
    TypedResourceStream& operator=(const TypedResourceStream&) = delete;
    TypedResourceStream(TypedResourceStream&&) noexcept = default;
    TypedResourceStream& operator=(TypedResourceStream&&) noexcept = default;

    explicit TypedResourceStream(ResourceStream stream)
        : stream_(std::move(stream)) {}

    [[nodiscard]] const StreamId& id() const noexcept { return stream_.id(); }
    [[nodiscard]] const std::optional<std::string>& attachment_lease() const noexcept {
        return stream_.attachment_lease();
    }

    [[nodiscard]] Result<std::optional<TypedStreamItem<T>>> next() {
        auto raw = stream_.next();
        if (!raw) {
            return std::move(raw).error();
        }
        if (!raw.value()) {
            return std::optional<TypedStreamItem<T>>{};
        }
        auto decoded = detail::decode_stream_domain<T>(
            raw.value()->value, raw.value()->cursor);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return std::optional<TypedStreamItem<T>>(TypedStreamItem<T>{
            raw.value()->sequence,
            raw.value()->cursor,
            std::move(decoded).value(),
        });
    }

    [[nodiscard]] Result<std::optional<TypedStreamItem<T>>> next(
        Timeout timeout) {
        auto raw = stream_.next(timeout);
        if (!raw) {
            return std::move(raw).error();
        }
        if (!raw.value()) {
            return std::optional<TypedStreamItem<T>>{};
        }
        auto decoded = detail::decode_stream_domain<T>(
            raw.value()->value, raw.value()->cursor);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return std::optional<TypedStreamItem<T>>(TypedStreamItem<T>{
            raw.value()->sequence,
            raw.value()->cursor,
            std::move(decoded).value(),
        });
    }

    [[nodiscard]] Result<std::optional<TypedStreamItem<T>>> poll(
        Timeout timeout) {
        return next(timeout);
    }

    [[nodiscard]] Result<Json> connection_control(
        Operation operation,
        Json::Object params = {}) {
        return stream_.connection_control(operation, std::move(params));
    }
    [[nodiscard]] Result<StreamEnd> cancel() { return stream_.cancel(); }
    [[nodiscard]] bool closed() const noexcept { return stream_.closed(); }
    [[nodiscard]] const std::optional<StreamEnd>& end() const noexcept {
        return stream_.end();
    }

protected:
    ResourceStream stream_;
};

using SessionEventStream = TypedResourceStream<SessionEvent>;
using SessionJournalStream = TypedResourceStream<SessionJournalRecord>;

class TerminalAttachmentStream final
    : public TypedResourceStream<TerminalAttachmentItem> {
public:
    using TypedResourceStream::TypedResourceStream;

    [[nodiscard]] Result<ViewerResizeResult> resize_viewer(
        std::uint16_t columns,
        std::uint16_t rows);
    [[nodiscard]] Result<ViewerReleaseResult> release_viewer();
};

class BrowserAttachmentStream final
    : public TypedResourceStream<BrowserAttachmentItem> {
public:
    using TypedResourceStream::TypedResourceStream;

    [[nodiscard]] Result<BrowserViewerResizeResult> resize_viewer(
        std::uint32_t width_px,
        std::uint32_t height_px);
    [[nodiscard]] Result<ViewerReleaseResult> release_viewer();
};

using SidebarViewStream = TypedResourceStream<SidebarViewItem>;
struct PaneLocation {
    Selector<WorkspaceId> workspace;
    Selector<ScreenId> screen;
    Selector<PaneId> pane;
};

struct PaneDestination {
    Selector<WorkspaceId> workspace;
    Selector<ScreenId> screen;
    Selector<PaneId> pane;
    std::size_t index = 0;
};

class OptionalStringUpdate {
public:
    enum class State {
        unchanged,
        set,
        clear,
    };

    [[nodiscard]] static OptionalStringUpdate unchanged() {
        return OptionalStringUpdate(State::unchanged, {});
    }
    [[nodiscard]] static OptionalStringUpdate set(std::string value) {
        return OptionalStringUpdate(State::set, std::move(value));
    }
    [[nodiscard]] static OptionalStringUpdate clear() {
        return OptionalStringUpdate(State::clear, {});
    }
    [[nodiscard]] State state() const noexcept { return state_; }
    [[nodiscard]] const std::string& value() const noexcept { return value_; }

private:
    OptionalStringUpdate(State state, std::string value)
        : state_(state), value_(std::move(value)) {}
    State state_ = State::unchanged;
    std::string value_;
};

struct ClientMetadataUpdate {
    OptionalStringUpdate name = OptionalStringUpdate::unchanged();
    OptionalStringUpdate kind = OptionalStringUpdate::unchanged();
};

class Client;
class Machine;
class Session;
class Workspace;
class Screen;
class Pane;
class Tab;
class Terminal;
class Browser;

template <typename Id>
class ResourceHandle {
public:
    ResourceHandle() = default;

    [[nodiscard]] const Selector<Id>& selector() const noexcept {
        return selector_;
    }
    [[nodiscard]] const std::optional<Id>& selected_id() const noexcept {
        return selected_id_;
    }
    [[nodiscard]] const Id& id() const {
        if (!selected_id_) {
            throw std::logic_error(
                "resource handle uses a current or name selector");
        }
        return *selected_id_;
    }

    [[nodiscard]] detail::ResourceReadResult read(
        Operation operation,
        Json::Object params = {},
        CallOptions call = {}) const {
        if (!state_) {
            return detail::ResourceReadResult(make_error(
                ErrorCode::closed, "resource handle has no client"));
        }
        return detail::ResourceReadResult(detail::resource_read(
            state_,
            operation,
            routed_params(std::move(params)),
            std::move(call)));
    }

    [[nodiscard]] detail::ResourceMutationResult mutate(
        Operation operation,
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique(),
        CallOptions call = {}) const;

public:
    ResourceHandle(
        std::shared_ptr<detail::ResourceClientState> state,
        Selector<Id> selector,
        std::string scope,
        Json::Object ancestors = {})
        : state_(std::move(state)),
          selector_(std::move(selector)),
          selected_id_(selector_.selected_id()),
          route_(std::move(ancestors)) {
        if (selector_.kind() != Selector<Id>::Kind::id) {
            detail::complete_structural_route(route_, scope);
        }
        route_.insert_or_assign(std::move(scope), Json(selector_.wire()));
    }
    ResourceHandle(
        std::shared_ptr<detail::ResourceClientState> state,
        Id id,
        std::string scope,
        Json::Object ancestors = {})
        : ResourceHandle(
              std::move(state),
              Selector<Id>::by_id(std::move(id)),
              std::move(scope),
              std::move(ancestors)) {}

protected:
    [[nodiscard]] Json::Object routed_params(Json::Object params = {}) const {
        for (const auto& [scope, selector] : route_) {
            params.insert_or_assign(scope, selector);
        }
        return params;
    }
    std::shared_ptr<detail::ResourceClientState> state_;
    Selector<Id> selector_{Selector<Id>::current()};
    std::optional<Id> selected_id_;
    Json::Object route_;
};

class Machine final : public ResourceHandle<MachineId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<MachineSnapshot> refresh() const;
    [[nodiscard]] Result<std::vector<SessionSnapshot>> sessions() const;
    [[nodiscard]] Session session(Selector<SessionId> selector) const;
    [[nodiscard]] Session session(SessionId id) const;
};

class Session final : public ResourceHandle<SessionId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<SessionSnapshot> refresh() const;
    [[nodiscard]] Result<ResourceSnapshot> snapshot() const;
    [[nodiscard]] Result<PingResult> ping() const;
    [[nodiscard]] Result<CreationResolution> resolve_creation(
        std::string correlation_key) const;
    [[nodiscard]] Result<std::vector<WorkspaceSnapshot>> workspaces() const;
    [[nodiscard]] Result<std::vector<NotificationSnapshot>> notifications(
        std::optional<std::uint32_t> limit = std::nullopt) const;
    [[nodiscard]] Result<MutationResult<NotificationSnapshot>>
    create_notification(
        NotificationCreateOptions create,
        MutationOptions mutation = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<AgentSnapshot>> report_agent(
        AgentReportOptions report,
        MutationOptions mutation = MutationOptions::unique()) const;
    [[nodiscard]] Workspace workspace(
        Selector<WorkspaceId> selector) const;
    [[nodiscard]] Workspace workspace(WorkspaceId id) const;
    [[nodiscard]] Result<MutationResult<CreatedPath>> create_workspace(
        CreateWorkspaceOptions create = {},
        MutationOptions mutation = MutationOptions::unique()) const;
    [[nodiscard]] Result<SessionEventStream> events(
        std::optional<Cursor> cursor = std::nullopt,
        CallOptions call = {}) const;
    [[nodiscard]] Result<SessionJournalStream> journal(
        SessionJournalOptions options = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<MutationResult<ShutdownResult>> shutdown(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<ReloadConfigResult>> reload_config(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TerminalDefaultsSnapshot>>
    update_terminal_defaults(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> set_window_title(
        std::string title,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> clear_window_title(
        MutationOptions options = MutationOptions::unique()) const;
};

class Workspace final : public ResourceHandle<WorkspaceId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<WorkspaceSnapshot> refresh() const;
    [[nodiscard]] Result<std::vector<ScreenSnapshot>> screens() const;
    [[nodiscard]] Screen screen(Selector<ScreenId> selector) const;
    [[nodiscard]] Screen screen(ScreenId id) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>> create_screen(
        CreateScreenOptions create = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<WorkspaceSnapshot>> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<WorkspaceSnapshot>> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<WorkspaceSnapshot>> move(
        std::size_t index,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<WorkspaceSnapshot>> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>> run(
        RunOptions run,
        MutationOptions options = MutationOptions::unique(),
        CallOptions call = {}) const;
    [[nodiscard]] Result<MutationResult<WorkspaceSnapshot>> apply_layout(
        Json document,
        MutationOptions options = MutationOptions::unique()) const;
};

class Screen final : public ResourceHandle<ScreenId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ScreenSnapshot> refresh() const;
    [[nodiscard]] Result<std::vector<PaneSnapshot>> panes() const;
    [[nodiscard]] Pane pane(Selector<PaneId> selector) const;
    [[nodiscard]] Pane pane(PaneId id) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>> create_pane(
        CreatePaneOptions create = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<ScreenSnapshot>> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<ScreenSnapshot>> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<ScreenSnapshot>> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<LayoutDocument> export_layout() const;
    [[nodiscard]] Result<MutationResult<ScreenSnapshot>> undo_layout(
        UndoLayoutOptions undo = {},
        MutationOptions options = MutationOptions::unique()) const;
};

class Pane final : public ResourceHandle<PaneId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<PaneSnapshot> refresh() const;
    [[nodiscard]] Result<std::vector<TabSnapshot>> tabs() const;
    [[nodiscard]] Tab tab(Selector<TabId> selector) const;
    [[nodiscard]] Tab tab(TabId id) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>> split(
        SplitPaneOptions split,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> focus_direction(
        std::string direction,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<PaneNeighborResult> neighbor(
        std::string direction) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> swap(
        PaneLocation other,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> zoom(
        std::optional<bool> zoomed = std::nullopt,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> set_split_ratio(
        SplitId split,
        double ratio,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<PaneSnapshot>> set_viewport_width(
        std::uint16_t columns,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>> run(
        RunOptions run,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<CreatedTerminalPath>>
    create_terminal_tab(
        CreateTerminalTabOptions create = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<CreatedBrowserPath>>
    create_browser_tab(
        CreateBrowserTabOptions create,
        MutationOptions options = MutationOptions::unique()) const;
};

class Tab final : public ResourceHandle<TabId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<TabSnapshot> refresh() const;
    [[nodiscard]] Terminal terminal(
        Selector<TerminalId> selector) const;
    [[nodiscard]] Terminal terminal(TerminalId id) const;
    [[nodiscard]] Browser browser(Selector<BrowserId> selector) const;
    [[nodiscard]] Browser browser(BrowserId id) const;
    [[nodiscard]] Result<MutationResult<TabSnapshot>> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TabSnapshot>> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TabSnapshot>> move(
        PaneDestination destination,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TabSnapshot>> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class Terminal final : public ResourceHandle<TerminalId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<TerminalSnapshot> refresh() const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> write(
        std::string text,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> keys(
        std::vector<std::string> keys,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> mouse(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> input_focus(
        bool focused,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<TerminalScreenResult> read_screen(
        Json::Object params = {}) const;
    [[nodiscard]] Result<TerminalStateResult> read_state() const;
    [[nodiscard]] Result<TerminalHistoryResult> read_history(
        TerminalHistoryOptions options = {}) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> clear_history(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<TerminalWaitResult> wait(
        std::string pattern,
        std::optional<std::uint64_t> timeout_ms = std::nullopt,
        CallOptions call = {}) const;
    [[nodiscard]] Result<TerminalWaitExitResult> wait_exit(
        std::optional<std::uint64_t> timeout_ms = std::nullopt,
        CallOptions call = {}) const;
    [[nodiscard]] Result<TerminalCopyResult> copy(
        Json::Object params = {}) const;
    [[nodiscard]] Result<ProcessInfoResult> process() const;
    [[nodiscard]] Result<RendererGrant> renderer_grant(
        Json::Object params = {}) const;
    [[nodiscard]] Result<ViewerResizeResult> resize_viewer(
        std::string attachment_lease,
        std::uint16_t columns,
        std::uint16_t rows) const;
    [[nodiscard]] Result<ViewerReleaseResult> release_viewer(
        std::string attachment_lease) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> scroll(
        std::int32_t delta_rows,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TerminalSnapshot>> move(
        PaneDestination destination,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<TabSnapshot>> project(
        PaneDestination destination,
        std::optional<std::string> name = std::nullopt,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<TerminalAttachmentStream> attach(
        TerminalAttachOptions options = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class Browser final : public ResourceHandle<BrowserId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<BrowserSnapshot> refresh() const;
    [[nodiscard]] Result<MutationResult<BrowserSnapshot>> navigate(
        std::string url,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<BrowserSnapshot>> back(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<BrowserSnapshot>> forward(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<BrowserSnapshot>> reload(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<BrowserSnapshot>> activate(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> key(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> text(
        std::string text,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> mouse(
        Json::Object params,
        std::uint64_t pointer_frame_seq,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> wheel(
        double delta_x,
        double delta_y,
        double x_px,
        double y_px,
        std::uint64_t pointer_frame_seq,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<BrowserViewerResizeResult> resize_viewer(
        std::string attachment_lease,
        std::uint32_t width_px,
        std::uint32_t height_px) const;
    [[nodiscard]] Result<ViewerReleaseResult> release_viewer(
        std::string attachment_lease) const;
    [[nodiscard]] Result<BrowserAttachmentStream> attach(
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<MutationResult<EmptyResult>> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class ConnectedClient final : public ResourceHandle<ConnectedClientId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ClientSnapshot> refresh() const;
    [[nodiscard]] Result<ClientSnapshot> update_metadata(
        ClientMetadataUpdate update) const;
    [[nodiscard]] Result<ClientSnapshot> set_name(std::string name) const;
    [[nodiscard]] Result<ClientSnapshot> clear_name() const;
    [[nodiscard]] Result<ClientSnapshot> set_kind(std::string kind) const;
    [[nodiscard]] Result<ClientSnapshot> clear_kind() const;
    [[nodiscard]] Result<ClientSnapshot> set_sizing(Json::Object params) const;
    [[nodiscard]] Result<ClientSnapshot> release_sizing(
        Json::Object params = {}) const;
    [[nodiscard]] Result<CellPixelsResult> set_cell_pixels(
        std::uint32_t width_px,
        std::uint32_t height_px) const;
    [[nodiscard]] Result<EmptyResult> detach() const;
};

template <typename Id>
class AuxiliaryHandle final : public ResourceHandle<Id> {
public:
    using ResourceHandle<Id>::ResourceHandle;
};

using Notification = AuxiliaryHandle<NotificationId>;
using Agent = AuxiliaryHandle<AgentId>;
using PairingRequest = AuxiliaryHandle<PairingRequestId>;
class FrontendProjection final : public ResourceHandle<FrontendProjectionId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<FrontendProjectionSnapshot> refresh() const;
    [[nodiscard]] Result<MutationResult<FrontendProjectionSnapshot>> put(
        ProjectionPutOptions projection,
        MutationOptions options = MutationOptions::unique()) const;
};
class SidebarView final : public ResourceHandle<SidebarViewId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<SidebarViewSnapshot> refresh() const;
    [[nodiscard]] Result<SidebarViewStream> attach(
        Json::Object params = {},
        CallOptions call = {}) const;
};
class Client {
public:
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;
    Client(Client&&) noexcept;
    Client& operator=(Client&&) noexcept;
    ~Client();

    [[nodiscard]] static Result<Client> connect(ClientOptions options = {});

    void close() noexcept;
    [[nodiscard]] bool closed() const noexcept;

    [[nodiscard]] Result<Json> read(
        Operation operation,
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<RawMutationResult> mutate(
        Operation operation,
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique(),
        CallOptions call = {}) const;
    [[nodiscard]] Result<Json> connection_control(
        Operation operation,
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<ResourceStream> open_stream(
        Operation operation,
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<SessionEventStream> open_session_events(
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<SessionJournalStream> open_session_journal(
        Json::Object params = {},
        CallOptions call = {}) const;
    [[nodiscard]] Result<TerminalAttachmentStream> open_terminal_attachment(
        Json::Object params,
        CallOptions call = {}) const;
    [[nodiscard]] Result<BrowserAttachmentStream> open_browser_attachment(
        Json::Object params,
        CallOptions call = {}) const;
    [[nodiscard]] Result<SidebarViewStream> open_sidebar_view(
        Json::Object params,
        CallOptions call = {}) const;

    [[nodiscard]] Machine machine(Selector<MachineId> selector) const;
    [[nodiscard]] Machine machine(MachineId id) const;
    [[nodiscard]] Session session(Selector<SessionId> selector) const;
    [[nodiscard]] Session session(SessionId id) const;
    [[nodiscard]] Workspace workspace(Selector<WorkspaceId> selector) const;
    [[nodiscard]] Workspace workspace(WorkspaceId id) const;
    [[nodiscard]] Screen screen(Selector<ScreenId> selector) const;
    [[nodiscard]] Screen screen(ScreenId id) const;
    [[nodiscard]] Pane pane(Selector<PaneId> selector) const;
    [[nodiscard]] Pane pane(PaneId id) const;
    [[nodiscard]] Tab tab(Selector<TabId> selector) const;
    [[nodiscard]] Tab tab(TabId id) const;
    [[nodiscard]] Terminal terminal(Selector<TerminalId> selector) const;
    [[nodiscard]] Terminal terminal(TerminalId id) const;
    [[nodiscard]] Browser browser(Selector<BrowserId> selector) const;
    [[nodiscard]] Browser browser(BrowserId id) const;
    [[nodiscard]] ConnectedClient connected_client(
        Selector<ConnectedClientId> selector) const;
    [[nodiscard]] ConnectedClient connected_client(ConnectedClientId id) const;
    [[nodiscard]] Notification notification(
        Selector<NotificationId> selector) const;
    [[nodiscard]] Notification notification(NotificationId id) const;
    [[nodiscard]] Agent agent(Selector<AgentId> selector) const;
    [[nodiscard]] Agent agent(AgentId id) const;
    [[nodiscard]] PairingRequest pairing_request(
        Selector<PairingRequestId> selector) const;
    [[nodiscard]] PairingRequest pairing_request(PairingRequestId id) const;
    [[nodiscard]] FrontendProjection projection(
        Selector<FrontendProjectionId> selector) const;
    [[nodiscard]] FrontendProjection projection(FrontendProjectionId id) const;
    [[nodiscard]] SidebarView sidebar_view(
        Selector<SidebarViewId> selector) const;
    [[nodiscard]] SidebarView sidebar_view(SidebarViewId id) const;
    [[nodiscard]] Result<std::vector<MachineSnapshot>> machines() const;
    [[nodiscard]] Result<std::vector<SessionSnapshot>> sessions(
        std::optional<Selector<MachineId>> machine = std::nullopt) const;
    [[nodiscard]] Result<MutationResult<SessionSnapshot>> open_session(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<std::vector<AgentSnapshot>> agents(
        Json::Object params = {}) const;
    [[nodiscard]] Result<std::vector<PairingRequestSnapshot>> pairing_requests(
        Json::Object params = {}) const;

private:
    explicit Client(std::shared_ptr<detail::ResourceClientState> state);
    std::shared_ptr<detail::ResourceClientState> state_;
};

template <typename Id>
detail::ResourceMutationResult ResourceHandle<Id>::mutate(
    Operation operation,
    Json::Object params,
    MutationOptions options,
    CallOptions call) const {
    if (!state_) {
        return detail::ResourceMutationResult(make_error(
            ErrorCode::closed, "resource handle has no client"));
    }
    return detail::ResourceMutationResult(detail::resource_mutate(
        state_,
        operation,
        routed_params(std::move(params)),
        std::move(options),
        std::move(call)));
}

// Lowercase alias for projects that standardize on result<T>.
template <typename T>
using result = Result<T>;

}  // namespace cmux
