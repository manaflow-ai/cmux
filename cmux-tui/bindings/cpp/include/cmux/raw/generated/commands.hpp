#pragma once

#include <cstdint>
#include <span>
#include <string_view>
#include <utility>

#include "cmux/raw/client_core.hpp"
#include "cmux/raw/generated/events.hpp"

namespace cmux::raw {

struct CommandFieldRequirement {
    std::string_view name;
    std::uint32_t since;
    std::string_view capability;
};

struct CommandMetadata {
    std::string_view name;
    std::string_view authority;
    std::uint32_t since;
    std::string_view capability;
    bool streaming;
    std::string_view stream_kind;
    std::string_view terminal_event;
    std::span<const CommandFieldRequirement> field_requirements;
};

[[nodiscard]] std::span<const CommandMetadata> command_metadata() noexcept;

class Client {
public:
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;
    Client(Client&&) noexcept = default;
    Client& operator=(Client&&) noexcept = default;
    ~Client() = default;

    [[nodiscard]] static Result<Client> connect(ClientOptions options = {});
    void close() noexcept { core_.close(); }
    [[nodiscard]] bool closed() const noexcept { return core_.closed(); }

    [[nodiscard]] Result<ApplyLayoutResult> apply_layout(const ApplyLayoutRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EventStream> attach_surface(const AttachSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_activate(const BrowserActivateRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_back(const BrowserBackRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_forward(const BrowserForwardRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_frame_presented(const BrowserFramePresentedRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_insert_text(const BrowserInsertTextRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_key(const BrowserKeyRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_key_press(const BrowserKeyPressRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_mouse(const BrowserMouseRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_mouse_guarded(const BrowserMouseGuardedRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_navigate(const BrowserNavigateRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_reload(const BrowserReloadRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_wheel(const BrowserWheelRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> browser_wheel_guarded(const BrowserWheelGuardedRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> clear_history(const ClearHistoryRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> clear_window_title(const ClearWindowTitleRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<ClientFocusResult> client_focus(const ClientFocusRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> close_pane(const ClosePaneRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ProviderWorkspaceMutationResult> close_provider_managed_workspace(const CloseProviderManagedWorkspaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> close_screen(const CloseScreenRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> close_surface(const CloseSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<CloseTerminalResult> close_terminal(const CloseTerminalRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<WorkspaceMutationResult> close_workspace(const CloseWorkspaceRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<CopyResult> copy(const CopyRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<JsonValue> create_surface_with_receipt(const CreateSurfaceWithReceiptRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<TerminalPlacement> create_terminal(const CreateTerminalRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<WorkspaceMutationResult> create_workspace(const CreateWorkspaceRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<AttachedViewOutcomeResult> detach_attached_view(const DetachAttachedViewRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> detach_client(const DetachClientRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ExportLayoutResult> export_layout(const ExportLayoutRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<FocusDirectionResult> focus_direction(const FocusDirectionRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> focus_pane(const FocusPaneRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<BrowserProviderSnapshot> get_browser_provider(const GetBrowserProviderRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<GetCellPixelsResult> get_cell_pixels(const GetCellPixelsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<FrontendProjection> get_frontend_projection(const GetFrontendProjectionRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<IdentifyResult> identify(const IdentifyRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<IdsResult> ids(const IdsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<JournalFrontendEventResult> journal_frontend_event(const JournalFrontendEventRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ListAgentsResult> list_agents(const ListAgentsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<ListClientsResult> list_clients(const ListClientsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<ListTerminalsResult> list_terminals(const ListTerminalsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<Tree> list_workspaces(const ListWorkspacesRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> mark_workspaces_provider_managed(const MarkWorkspacesProviderManagedRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<MintTerminalRendererResult> mint_terminal_renderer(const MintTerminalRendererRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<MintTerminalRendererResult> mint_terminal_renderer_by_terminal(const MintTerminalRendererByTerminalRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> move_tab(const MoveTabRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<MoveTerminalResult> move_terminal(const MoveTerminalRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<WorkspaceMutationResult> move_workspace(const MoveWorkspaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_browser_tab(const NewBrowserTabRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_pane(const NewPaneRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_pane_right(const NewPaneRightRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_screen(const NewScreenRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_tab(const NewTabRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> new_workspace(const NewWorkspaceRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<NotifyResult> notify(const NotifyRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> pairing_response(const PairingResponseRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<PaneNeighborResult> pane_neighbor(const PaneNeighborRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<PingResult> ping(const PingRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<ProcessInfoResult> process_info(const ProcessInfoRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<FrontendProjection> put_frontend_projection(const PutFrontendProjectionRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ReadScreenResult> read_screen(const ReadScreenRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ReadScrollbackResult> read_scrollback(const ReadScrollbackRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<BrowserProviderSnapshot> register_browser_provider(const RegisterBrowserProviderRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<AttachedViewOutcomeResult> release_attached_view_size(const ReleaseAttachedViewSizeRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> release_surface_size(const ReleaseSurfaceSizeRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ReloadConfigResult> reload_config(const ReloadConfigRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> rename_pane(const RenamePaneRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ProviderWorkspaceMutationResult> rename_provider_managed_workspace(const RenameProviderManagedWorkspaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> rename_screen(const RenameScreenRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> rename_surface(const RenameSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<WorkspaceMutationResult> rename_workspace(const RenameWorkspaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ReportAgentResult> report_agent(const ReportAgentRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> report_focus(const ReportFocusRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<AttachedViewResizeResult> resize_attached_view(const ResizeAttachedViewRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ResizeSurfaceResult> resize_surface(const ResizeSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ResolveTerminalResult> resolve_terminal(const ResolveTerminalRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<RunResult> run(const RunRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> scroll_surface(const ScrollSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> select_screen(const SelectScreenRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> select_tab(const SelectTabRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> select_workspace(const SelectWorkspaceRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> send(const SendRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> send_key(const SendKeyRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SetCellPixelsResult> set_cell_pixels(const SetCellPixelsRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_client_info(const SetClientInfoRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_client_sizing(const SetClientSizingRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_default_colors(const SetDefaultColorsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_ratio(const SetRatioRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_split_ratio(const SetSplitRatioRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_viewport_pane_width(const SetViewportPaneWidthRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> set_window_title(const SetWindowTitleRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ShutdownDaemonResult> shutdown_daemon(const ShutdownDaemonRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SidebarPluginResult> sidebar_plugin(const SidebarPluginRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<SurfaceResult> split(const SplitRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<EventStream> subscribe(const SubscribeRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<EmptyResult> swap_pane(const SwapPaneRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<TerminalEventsResult> terminal_events(const TerminalEventsRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<LayoutUndoResult> undo_layout(const UndoLayoutRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<BrowserProviderUnregisterResult> unregister_browser_provider(const UnregisterBrowserProviderRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<VtStateResult> vt_state(const VtStateRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<WaitForResult> wait_for(const WaitForRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<ZoomPaneResult> zoom_pane(const ZoomPaneRequest& request = {}, RequestOptions options = {});

    [[nodiscard]] Result<DeltaStream> subscribe_deltas(
        const SubscribeRequest& request = {}, RequestOptions options = {});
    [[nodiscard]] Result<ByteStream> attach_bytes(
        const AttachSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<RenderStream> attach_render(
        const AttachSurfaceRequest& request, RequestOptions options = {});
    [[nodiscard]] Result<BrowserStream> attach_browser(
        const AttachSurfaceRequest& request, RequestOptions options = {});

private:
    explicit Client(detail::ClientCore core) : core_(std::move(core)) {}
    [[nodiscard]] Result<EventStream> open_event_stream(
        std::string_view command, Json::Object parameters,
        std::string terminal_event, RequestOptions options);
    detail::ClientCore core_;
};

}  // namespace cmux::raw
