#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <optional>
#include <ostream>
#include <span>
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
struct MutationResult;

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
    machine_create,
    machine_rename,
    machine_delete,
    machine_restore,
    machine_purge,
    machine_connect_external,
    session_list,
    session_open,
    session_get,
    session_snapshot,
    session_events,
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
    terminal_copy,
    terminal_process_get,
    terminal_renderer_grant_create,
    terminal_viewer_resize,
    terminal_viewer_release,
    terminal_viewport_scroll,
    terminal_move,
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
    provider_scope_list,
    provider_action_invoke,
    provider_notice_acknowledge,
    provider_notice_events,
    provider_workspace_mark,
    provider_workspace_rename,
    provider_workspace_close,
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
    Json::Object params);
[[nodiscard]] Result<Json> resource_control(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params);
[[nodiscard]] Result<MutationResult> resource_mutate(
    const std::shared_ptr<ResourceClientState>& state,
    Operation operation,
    Json::Object params,
    MutationOptions options);

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
using ProviderScopeId = OpaqueId<"provider_scope_">;
using ProviderActionId = OpaqueId<"provider_action_">;
using ProviderNoticeId = OpaqueId<"provider_notice_">;

template <typename Id>
class Selector {
public:
    enum class Kind {
        id,
        current,
        name,
    };

    [[nodiscard]] static Selector by_id(Id id) {
        return Selector(Kind::id, id.value());
    }
    [[nodiscard]] static Selector current() {
        return Selector(Kind::current, "current");
    }
    [[nodiscard]] static Selector exact_name(std::string name) {
        return Selector(Kind::name, std::move(name));
    }

    [[nodiscard]] Kind kind() const noexcept { return kind_; }
    [[nodiscard]] const std::string& value() const noexcept { return value_; }

    // Names are always explicitly tagged. This avoids ambiguity with
    // "current", opaque-ID-shaped names, and future selector syntax.
    [[nodiscard]] std::string wire() const {
        return kind_ == Kind::name ? "name:" + value_ : value_;
    }

private:
    Selector(Kind kind, std::string value)
        : kind_(kind), value_(std::move(value)) {}

    Kind kind_;
    std::string value_;
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
};

struct RunOptions {
    explicit RunOptions(RunCommand command_value)
        : command(std::move(command_value)) {}

    RunCommand command;
    std::optional<std::string> cwd;
    std::optional<std::string> name;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreateTerminalTabOptions {
    std::optional<std::string> cwd;
    std::optional<std::string> name;
    std::optional<std::uint16_t> columns;
    std::optional<std::uint16_t> rows;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct CreateBrowserTabOptions {
    explicit CreateBrowserTabOptions(std::string initial_url)
        : url(std::move(initial_url)) {}

    std::string url;
    std::optional<std::string> name;
    std::optional<std::uint32_t> width_px;
    std::optional<std::uint32_t> height_px;

    [[nodiscard]] Result<Json::Object> to_params() const;
};

struct Cursor {
    std::string generation;
    std::uint64_t revision = 0;
};

struct ParentIds {
    std::optional<MachineId> machine;
    std::optional<SessionId> session;
    std::optional<WorkspaceId> workspace;
    std::optional<ScreenId> screen;
    std::optional<PaneId> pane;
    std::optional<TabId> tab;
};

template <typename Id>
struct ResourceSnapshot {
    Id id;
    std::optional<std::string> name;
    std::optional<std::string> label;
    ParentIds parents;
    std::optional<std::uint64_t> revision;
    Json raw;
};

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

struct MutationResult {
    Json value;
    std::string generation;
    std::uint64_t revision = 0;
    bool replayed = false;

    [[nodiscard]] Result<std::optional<CreatedPath>> created_path() const;
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

using ProviderCredential = SensitiveString;

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
    [[nodiscard]] Result<std::optional<RawStreamItem>> next();
    [[nodiscard]] Result<std::optional<RawStreamItem>> next(Timeout timeout);
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
    Json::Object params);

}  // namespace detail

struct SessionEvent {
    std::string event;
    Json data;
    Json extra;
};

struct TerminalAttachmentItem {
    std::string kind;
    Json data;
    Json extra;
};

struct BrowserAttachmentItem {
    std::string kind;
    Json data;
    Json extra;
};

struct SidebarViewItem {
    std::string kind;
    Json data;
    Json extra;
};

struct ProviderNotice {
    std::string kind;
    Json data;
    Json extra;
};

template <typename T>
struct TypedStreamItem {
    std::uint64_t sequence = 0;
    std::optional<Cursor> cursor;
    T value;
};

namespace detail {

template <typename T>
[[nodiscard]] Result<T> decode_stream_domain(const Json& value) {
    auto object = value.as_object();
    if (!object) {
        return make_error(ErrorCode::decode, "stream item must be an object");
    }
    std::string kind = "unknown";
    if (const Json* event = value.find("event")) {
        auto text = event->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "stream event must be a string");
        }
        kind = std::string(text.value());
    } else if (const Json* type = value.find("type")) {
        auto text = type->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "stream item type must be a string");
        }
        kind = std::string(text.value());
    } else if (const Json* named_kind = value.find("kind")) {
        auto text = named_kind->as_string();
        if (!text) {
            return make_error(ErrorCode::decode, "stream item kind must be a string");
        }
        kind = std::string(text.value());
    }
    Json data = value.find("data") ? *value.find("data") : value;
    return T{std::move(kind), std::move(data), value};
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

    [[nodiscard]] Result<std::optional<TypedStreamItem<T>>> next() {
        auto raw = stream_.next();
        if (!raw) {
            return std::move(raw).error();
        }
        if (!raw.value()) {
            return std::optional<TypedStreamItem<T>>{};
        }
        auto decoded = detail::decode_stream_domain<T>(raw.value()->value);
        if (!decoded) {
            return std::move(decoded).error();
        }
        return std::optional<TypedStreamItem<T>>(TypedStreamItem<T>{
            raw.value()->sequence,
            raw.value()->cursor,
            std::move(decoded).value(),
        });
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

private:
    ResourceStream stream_;
};

using SessionEventStream = TypedResourceStream<SessionEvent>;
using TerminalAttachmentStream = TypedResourceStream<TerminalAttachmentItem>;
using BrowserAttachmentStream = TypedResourceStream<BrowserAttachmentItem>;
using SidebarViewStream = TypedResourceStream<SidebarViewItem>;
using ProviderNoticeStream = TypedResourceStream<ProviderNotice>;

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

template <typename Id>
class ResourceHandle {
public:
    ResourceHandle() = default;

    [[nodiscard]] const Id& id() const noexcept { return id_; }

    [[nodiscard]] Result<Json> read(
        Operation operation,
        Json::Object params = {}) const {
        if (!state_) {
            return make_error(ErrorCode::closed, "resource handle has no client");
        }
        params.insert_or_assign(scope_, Json(id_.value()));
        return detail::resource_read(state_, operation, std::move(params));
    }

    [[nodiscard]] Result<MutationResult> mutate(
        Operation operation,
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique()) const;

public:
    ResourceHandle(
        std::shared_ptr<detail::ResourceClientState> state,
        Id id,
        std::string scope)
        : state_(std::move(state)), id_(std::move(id)), scope_(std::move(scope)) {}

    std::shared_ptr<detail::ResourceClientState> state_;
    Id id_;
    std::string scope_;
};

class Machine final : public ResourceHandle<MachineId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<MachineId>> refresh() const;
    [[nodiscard]] Result<Json> sessions() const;
    [[nodiscard]] Result<MutationResult> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> remove(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> restore(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> purge(
        MutationOptions options = MutationOptions::unique()) const;
};

class Session final : public ResourceHandle<SessionId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<SessionId>> refresh() const;
    [[nodiscard]] Result<Json> snapshot() const;
    [[nodiscard]] Result<Json> ping() const;
    [[nodiscard]] Result<Json> workspaces() const;
    [[nodiscard]] Result<MutationResult> create_workspace(
        CreateWorkspaceOptions create = {},
        MutationOptions mutation = MutationOptions::unique()) const;
    [[nodiscard]] Result<SessionEventStream> events(
        std::optional<Cursor> cursor = std::nullopt) const;
    [[nodiscard]] Result<MutationResult> shutdown(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> reload_config(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> update_terminal_defaults(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> set_window_title(
        std::string title,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_window_title(
        MutationOptions options = MutationOptions::unique()) const;
};

class Workspace final : public ResourceHandle<WorkspaceId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<WorkspaceId>> refresh() const;
    [[nodiscard]] Result<Json> screens() const;
    [[nodiscard]] Result<MutationResult> create_screen(
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> move(
        std::size_t index,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> run(
        RunOptions run,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> apply_layout(
        Json document,
        MutationOptions options = MutationOptions::unique()) const;
};

class Screen final : public ResourceHandle<ScreenId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<ScreenId>> refresh() const;
    [[nodiscard]] Result<Json> panes() const;
    [[nodiscard]] Result<MutationResult> create_pane(
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> export_layout() const;
    [[nodiscard]] Result<MutationResult> undo_layout(
        MutationOptions options = MutationOptions::unique()) const;
};

class Pane final : public ResourceHandle<PaneId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<PaneId>> refresh() const;
    [[nodiscard]] Result<Json> tabs() const;
    [[nodiscard]] Result<MutationResult> split(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> focus_direction(
        std::string direction,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> neighbor(std::string direction) const;
    [[nodiscard]] Result<MutationResult> swap(
        PaneLocation other,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> zoom(
        std::optional<bool> zoomed = std::nullopt,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> set_split_ratio(
        SplitId split,
        double ratio,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> set_viewport_width(
        std::uint16_t columns,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> run(
        RunOptions run,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> create_terminal_tab(
        CreateTerminalTabOptions create = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> create_browser_tab(
        CreateBrowserTabOptions create,
        MutationOptions options = MutationOptions::unique()) const;
};

class Tab final : public ResourceHandle<TabId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<TabId>> refresh() const;
    [[nodiscard]] Result<MutationResult> rename(
        std::string name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> clear_name(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> move(
        PaneDestination destination,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> focus(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class Terminal final : public ResourceHandle<TerminalId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<TerminalId>> refresh() const;
    [[nodiscard]] Result<MutationResult> write(
        std::string text,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> keys(
        std::vector<std::string> keys,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> mouse(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> input_focus(
        bool focused,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> read_screen(Json::Object params = {}) const;
    [[nodiscard]] Result<Json> read_state() const;
    [[nodiscard]] Result<Json> read_history(Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> clear_history(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> wait(
        std::string pattern,
        std::optional<std::uint64_t> timeout_ms = std::nullopt) const;
    [[nodiscard]] Result<Json> copy(Json::Object params = {}) const;
    [[nodiscard]] Result<Json> process() const;
    [[nodiscard]] Result<RendererGrant> renderer_grant(
        Json::Object params = {}) const;
    [[nodiscard]] Result<Json> resize_viewer(
        std::uint16_t columns,
        std::uint16_t rows) const;
    [[nodiscard]] Result<Json> release_viewer() const;
    [[nodiscard]] Result<MutationResult> scroll(
        std::int32_t delta_rows,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> move(
        PaneDestination destination,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<TerminalAttachmentStream> attach(
        Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class Browser final : public ResourceHandle<BrowserId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<BrowserId>> refresh() const;
    [[nodiscard]] Result<MutationResult> navigate(
        std::string url,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> back(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> forward(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> reload(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> activate(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> key(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> text(
        std::string text,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> mouse(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> wheel(
        double delta_x,
        double delta_y,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> resize_viewer(
        std::uint32_t width_px,
        std::uint32_t height_px) const;
    [[nodiscard]] Result<Json> release_viewer() const;
    [[nodiscard]] Result<BrowserAttachmentStream> attach(
        Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> close(
        MutationOptions options = MutationOptions::unique()) const;
};

class ConnectedClient final : public ResourceHandle<ConnectedClientId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<ResourceSnapshot<ConnectedClientId>> refresh() const;
    [[nodiscard]] Result<Json> update_metadata(
        ClientMetadataUpdate update) const;
    [[nodiscard]] Result<Json> set_name(std::string name) const;
    [[nodiscard]] Result<Json> clear_name() const;
    [[nodiscard]] Result<Json> set_kind(std::string kind) const;
    [[nodiscard]] Result<Json> clear_kind() const;
    [[nodiscard]] Result<Json> set_sizing(Json::Object params) const;
    [[nodiscard]] Result<Json> release_sizing(Json::Object params = {}) const;
    [[nodiscard]] Result<Json> set_cell_pixels(
        std::uint32_t width_px,
        std::uint32_t height_px) const;
    [[nodiscard]] Result<Json> detach() const;
};

template <typename Id>
class AuxiliaryHandle final : public ResourceHandle<Id> {
public:
    using ResourceHandle<Id>::ResourceHandle;
};

using Notification = AuxiliaryHandle<NotificationId>;
using Agent = AuxiliaryHandle<AgentId>;
using PairingRequest = AuxiliaryHandle<PairingRequestId>;
using FrontendProjection = AuxiliaryHandle<FrontendProjectionId>;
class SidebarView final : public ResourceHandle<SidebarViewId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<Json> refresh() const;
    [[nodiscard]] Result<SidebarViewStream> attach(
        Json::Object params = {}) const;
};
class ProviderNoticeHandle;
class ProviderScope final : public ResourceHandle<ProviderScopeId> {
public:
    using ResourceHandle::ResourceHandle;
    [[nodiscard]] Result<MutationResult> create_machine(
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> connect_external(
        const SensitiveString& specifier,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> invoke(
        ProviderActionId action,
        Json::Object parameters,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<ProviderNoticeStream> notices(
        std::optional<Cursor> cursor = std::nullopt) const;
    [[nodiscard]] ProviderNoticeHandle notice(ProviderNoticeId id) const;
    [[nodiscard]] Result<MutationResult> mark_workspace(
        SessionId session,
        WorkspaceId workspace,
        bool managed,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> rename_workspace(
        SessionId session,
        WorkspaceId workspace,
        std::optional<std::string> name,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> close_workspace(
        SessionId session,
        WorkspaceId workspace,
        MutationOptions options = MutationOptions::unique()) const;
};
using ProviderAction = AuxiliaryHandle<ProviderActionId>;
class ProviderNoticeHandle final : public ResourceHandle<ProviderNoticeId> {
public:
    ProviderNoticeHandle(
        std::shared_ptr<detail::ResourceClientState> state,
        ProviderNoticeId id,
        std::string scope,
        std::optional<ProviderScopeId> provider_scope = std::nullopt)
        : ResourceHandle(
              std::move(state),
              std::move(id),
              std::move(scope)),
          provider_scope_(std::move(provider_scope)) {}

    [[nodiscard]] Result<Json> acknowledge(std::uint64_t sequence) const;

private:
    std::optional<ProviderScopeId> provider_scope_;
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
        Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> mutate(
        Operation operation,
        Json::Object params = {},
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> connection_control(
        Operation operation,
        Json::Object params = {}) const;
    [[nodiscard]] Result<ResourceStream> open_stream(
        Operation operation,
        Json::Object params = {}) const;
    [[nodiscard]] Result<SessionEventStream> open_session_events(
        Json::Object params = {}) const;
    [[nodiscard]] Result<TerminalAttachmentStream> open_terminal_attachment(
        Json::Object params) const;
    [[nodiscard]] Result<BrowserAttachmentStream> open_browser_attachment(
        Json::Object params) const;
    [[nodiscard]] Result<SidebarViewStream> open_sidebar_view(
        Json::Object params) const;
    [[nodiscard]] Result<ProviderNoticeStream> open_provider_notices(
        Json::Object params) const;

    [[nodiscard]] Machine machine(MachineId id) const;
    [[nodiscard]] Session session(SessionId id) const;
    [[nodiscard]] Workspace workspace(WorkspaceId id) const;
    [[nodiscard]] Screen screen(ScreenId id) const;
    [[nodiscard]] Pane pane(PaneId id) const;
    [[nodiscard]] Tab tab(TabId id) const;
    [[nodiscard]] Terminal terminal(TerminalId id) const;
    [[nodiscard]] Browser browser(BrowserId id) const;
    [[nodiscard]] ConnectedClient connected_client(ConnectedClientId id) const;
    [[nodiscard]] Notification notification(NotificationId id) const;
    [[nodiscard]] Agent agent(AgentId id) const;
    [[nodiscard]] PairingRequest pairing_request(PairingRequestId id) const;
    [[nodiscard]] FrontendProjection projection(FrontendProjectionId id) const;
    [[nodiscard]] SidebarView sidebar_view(SidebarViewId id) const;
    [[nodiscard]] ProviderScope provider_scope(ProviderScopeId id) const;
    [[nodiscard]] ProviderAction provider_action(ProviderActionId id) const;
    [[nodiscard]] ProviderNoticeHandle provider_notice(ProviderNoticeId id) const;

    [[nodiscard]] Result<Json> machines() const;
    [[nodiscard]] Result<Json> sessions(
        std::optional<Selector<MachineId>> machine = std::nullopt) const;
    [[nodiscard]] Result<MutationResult> create_machine(
        ProviderScopeId provider_scope,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> connect_external_machine(
        ProviderScopeId provider_scope,
        const SensitiveString& specifier,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<MutationResult> open_session(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> notifications(Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> notify(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> agents(Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> report_agent(
        Json::Object params,
        MutationOptions options = MutationOptions::unique()) const;
    [[nodiscard]] Result<Json> pairing_requests(Json::Object params = {}) const;
    [[nodiscard]] Result<Json> provider_scopes(Json::Object params = {}) const;
    [[nodiscard]] Result<MutationResult> invoke_provider_action(
        ProviderScopeId provider_scope,
        ProviderActionId action,
        Json::Object parameters,
        MutationOptions options = MutationOptions::unique()) const;

private:
    explicit Client(std::shared_ptr<detail::ResourceClientState> state);
    std::shared_ptr<detail::ResourceClientState> state_;
};

template <typename Id>
Result<MutationResult> ResourceHandle<Id>::mutate(
    Operation operation,
    Json::Object params,
    MutationOptions options) const {
    if (!state_) {
        return make_error(ErrorCode::closed, "resource handle has no client");
    }
    params.insert_or_assign(scope_, Json(id_.value()));
    return detail::resource_mutate(
        state_, operation, std::move(params), std::move(options));
}

// Lowercase alias for projects that standardize on result<T>.
template <typename T>
using result = Result<T>;

}  // namespace cmux
