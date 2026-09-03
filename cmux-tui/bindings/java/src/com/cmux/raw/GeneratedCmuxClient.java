// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.List;
import java.util.Map;


/** Canonical typed method surface for every implemented protocol command. */
public abstract class GeneratedCmuxClient {
    protected abstract Object execute(CommandMetadata metadata, Map<String, Object> params)
        throws CmuxException;
    protected abstract CmuxStream<ProtocolEvent> openStream(
        CommandMetadata metadata, Map<String, Object> params
    ) throws CmuxException;

    public final ApplyLayoutResult applyLayout(ApplyLayoutRequest request) throws CmuxException {
        Object result = execute(Commands.APPLY_LAYOUT, request.toWire());
        return ApplyLayoutResult.fromWire(result);
    }

    public final CmuxStream<ProtocolEvent> attachSurface(AttachSurfaceRequest request) throws CmuxException {
        return openStream(Commands.ATTACH_SURFACE, request.toWire());
    }

    public final EmptyResult browserActivate(BrowserActivateRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_ACTIVATE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserBack(BrowserBackRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_BACK, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserForward(BrowserForwardRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_FORWARD, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserFramePresented(BrowserFramePresentedRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_FRAME_PRESENTED, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserInsertText(BrowserInsertTextRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_INSERT_TEXT, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserKey(BrowserKeyRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_KEY, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserKeyPress(BrowserKeyPressRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_KEY_PRESS, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserMouse(BrowserMouseRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_MOUSE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserMouseGuarded(BrowserMouseGuardedRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_MOUSE_GUARDED, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserNavigate(BrowserNavigateRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_NAVIGATE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserReload(BrowserReloadRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_RELOAD, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserWheel(BrowserWheelRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_WHEEL, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult browserWheelGuarded(BrowserWheelGuardedRequest request) throws CmuxException {
        Object result = execute(Commands.BROWSER_WHEEL_GUARDED, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult clearHistory(ClearHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.CLEAR_HISTORY, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult clearWindowTitle() throws CmuxException {
        Object result = execute(Commands.CLEAR_WINDOW_TITLE, Map.of());
        return EmptyResult.fromWire(result);
    }

    public final ClientFocusResult clientFocus(ClientFocusRequest request) throws CmuxException {
        Object result = execute(Commands.CLIENT_FOCUS, request.toWire());
        return ClientFocusResult.fromWire(result);
    }

    public final EmptyResult closePane(ClosePaneRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_PANE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final ProviderWorkspaceMutationResult closeProviderManagedWorkspace(CloseProviderManagedWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_PROVIDER_MANAGED_WORKSPACE, request.toWire());
        return ProviderWorkspaceMutationResult.fromWire(result);
    }

    public final EmptyResult closeScreen(CloseScreenRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_SCREEN, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult closeSurface(CloseSurfaceRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_SURFACE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final CloseTerminalResult closeTerminal(CloseTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_TERMINAL, request.toWire());
        return CloseTerminalResult.fromWire(result);
    }

    public final WorkspaceMutationResult closeWorkspace(CloseWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_WORKSPACE, request.toWire());
        return WorkspaceMutationResult.fromWire(result);
    }

    public final CopyResult copy(CopyRequest request) throws CmuxException {
        Object result = execute(Commands.COPY, request.toWire());
        return CopyResult.fromWire(result);
    }

    public final Object createSurfaceWithReceipt(CreateSurfaceWithReceiptRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_SURFACE_WITH_RECEIPT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final TerminalPlacement createTerminal(CreateTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_TERMINAL, request.toWire());
        return TerminalPlacement.fromWire(result);
    }

    public final WorkspaceMutationResult createWorkspace(CreateWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_WORKSPACE, request.toWire());
        return WorkspaceMutationResult.fromWire(result);
    }

    public final AttachedViewOutcomeResult detachAttachedView(DetachAttachedViewRequest request) throws CmuxException {
        Object result = execute(Commands.DETACH_ATTACHED_VIEW, request.toWire());
        return AttachedViewOutcomeResult.fromWire(result);
    }

    public final EmptyResult detachClient(DetachClientRequest request) throws CmuxException {
        Object result = execute(Commands.DETACH_CLIENT, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final ExportLayoutResult exportLayout(ExportLayoutRequest request) throws CmuxException {
        Object result = execute(Commands.EXPORT_LAYOUT, request.toWire());
        return ExportLayoutResult.fromWire(result);
    }

    public final FocusDirectionResult focusDirection(FocusDirectionRequest request) throws CmuxException {
        Object result = execute(Commands.FOCUS_DIRECTION, request.toWire());
        return FocusDirectionResult.fromWire(result);
    }

    public final EmptyResult focusPane(FocusPaneRequest request) throws CmuxException {
        Object result = execute(Commands.FOCUS_PANE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final BrowserProviderSnapshot getBrowserProvider() throws CmuxException {
        Object result = execute(Commands.GET_BROWSER_PROVIDER, Map.of());
        return BrowserProviderSnapshot.fromWire(result);
    }

    public final GetCellPixelsResult getCellPixels() throws CmuxException {
        Object result = execute(Commands.GET_CELL_PIXELS, Map.of());
        return GetCellPixelsResult.fromWire(result);
    }

    public final FrontendProjection getFrontendProjection(GetFrontendProjectionRequest request) throws CmuxException {
        Object result = execute(Commands.GET_FRONTEND_PROJECTION, request.toWire());
        return FrontendProjection.fromWire(result);
    }

    public final IdentifyResult identify() throws CmuxException {
        Object result = execute(Commands.IDENTIFY, Map.of());
        return IdentifyResult.fromWire(result);
    }

    public final IdsResult ids(IdsRequest request) throws CmuxException {
        Object result = execute(Commands.IDS, request.toWire());
        return IdsResult.fromWire(result);
    }

    public final JournalFrontendEventResult journalFrontendEvent(JournalFrontendEventRequest request) throws CmuxException {
        Object result = execute(Commands.JOURNAL_FRONTEND_EVENT, request.toWire());
        return JournalFrontendEventResult.fromWire(result);
    }

    public final ListAgentsResult listAgents(ListAgentsRequest request) throws CmuxException {
        Object result = execute(Commands.LIST_AGENTS, request.toWire());
        return ListAgentsResult.fromWire(result);
    }

    public final List<ClientInfo> listClients() throws CmuxException {
        Object result = execute(Commands.LIST_CLIENTS, Map.of());
        return Wire.array(result, "list-clients result", item -> ClientInfo.fromWire(item));
    }

    public final ListTerminalsResult listTerminals() throws CmuxException {
        Object result = execute(Commands.LIST_TERMINALS, Map.of());
        return ListTerminalsResult.fromWire(result);
    }

    public final Tree listWorkspaces() throws CmuxException {
        Object result = execute(Commands.LIST_WORKSPACES, Map.of());
        return Tree.fromWire(result);
    }

    public final MachineUsageResult machineUsage() throws CmuxException {
        Object result = execute(Commands.MACHINE_USAGE, Map.of());
        return MachineUsageResult.fromWire(result);
    }

    public final EmptyResult markWorkspacesProviderManaged(MarkWorkspacesProviderManagedRequest request) throws CmuxException {
        Object result = execute(Commands.MARK_WORKSPACES_PROVIDER_MANAGED, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final MintTerminalRendererResult mintTerminalRenderer(MintTerminalRendererRequest request) throws CmuxException {
        Object result = execute(Commands.MINT_TERMINAL_RENDERER, request.toWire());
        return MintTerminalRendererResult.fromWire(result);
    }

    public final MintTerminalRendererResult mintTerminalRendererByTerminal(MintTerminalRendererByTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.MINT_TERMINAL_RENDERER_BY_TERMINAL, request.toWire());
        return MintTerminalRendererResult.fromWire(result);
    }

    public final EmptyResult moveTab(MoveTabRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final MoveTerminalResult moveTerminal(MoveTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TERMINAL, request.toWire());
        return MoveTerminalResult.fromWire(result);
    }

    public final WorkspaceMutationResult moveWorkspace(MoveWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_WORKSPACE, request.toWire());
        return WorkspaceMutationResult.fromWire(result);
    }

    public final SurfaceResult newBrowserTab(NewBrowserTabRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_BROWSER_TAB, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newPane(NewPaneRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_PANE, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newPaneRight(NewPaneRightRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_PANE_RIGHT, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newScreen(NewScreenRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_SCREEN, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newTab(NewTabRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_TAB, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newWorkspace(NewWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_WORKSPACE, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final NotifyResult notify(NotifyRequest request) throws CmuxException {
        Object result = execute(Commands.NOTIFY, request.toWire());
        return NotifyResult.fromWire(result);
    }

    public final EmptyResult pairingResponse(PairingResponseRequest request) throws CmuxException {
        Object result = execute(Commands.PAIRING_RESPONSE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final PaneNeighborResult paneNeighbor(PaneNeighborRequest request) throws CmuxException {
        Object result = execute(Commands.PANE_NEIGHBOR, request.toWire());
        return PaneNeighborResult.fromWire(result);
    }

    public final PingResult ping() throws CmuxException {
        Object result = execute(Commands.PING, Map.of());
        return PingResult.fromWire(result);
    }

    public final ProcessInfoResult processInfo(ProcessInfoRequest request) throws CmuxException {
        Object result = execute(Commands.PROCESS_INFO, request.toWire());
        return ProcessInfoResult.fromWire(result);
    }

    public final FrontendProjection putFrontendProjection(PutFrontendProjectionRequest request) throws CmuxException {
        Object result = execute(Commands.PUT_FRONTEND_PROJECTION, request.toWire());
        return FrontendProjection.fromWire(result);
    }

    public final ReadScreenResult readScreen(ReadScreenRequest request) throws CmuxException {
        Object result = execute(Commands.READ_SCREEN, request.toWire());
        return ReadScreenResult.fromWire(result);
    }

    public final ReadScrollbackResult readScrollback(ReadScrollbackRequest request) throws CmuxException {
        Object result = execute(Commands.READ_SCROLLBACK, request.toWire());
        return ReadScrollbackResult.fromWire(result);
    }

    public final BrowserProviderSnapshot registerBrowserProvider(RegisterBrowserProviderRequest request) throws CmuxException {
        Object result = execute(Commands.REGISTER_BROWSER_PROVIDER, request.toWire());
        return BrowserProviderSnapshot.fromWire(result);
    }

    public final AttachedViewOutcomeResult releaseAttachedViewSize(ReleaseAttachedViewSizeRequest request) throws CmuxException {
        Object result = execute(Commands.RELEASE_ATTACHED_VIEW_SIZE, request.toWire());
        return AttachedViewOutcomeResult.fromWire(result);
    }

    public final EmptyResult releaseSurfaceSize(ReleaseSurfaceSizeRequest request) throws CmuxException {
        Object result = execute(Commands.RELEASE_SURFACE_SIZE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final ReloadConfigResult reloadConfig() throws CmuxException {
        Object result = execute(Commands.RELOAD_CONFIG, Map.of());
        return ReloadConfigResult.fromWire(result);
    }

    public final EmptyResult renamePane(RenamePaneRequest request) throws CmuxException {
        Object result = execute(Commands.RENAME_PANE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final ProviderWorkspaceMutationResult renameProviderManagedWorkspace(RenameProviderManagedWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.RENAME_PROVIDER_MANAGED_WORKSPACE, request.toWire());
        return ProviderWorkspaceMutationResult.fromWire(result);
    }

    public final EmptyResult renameScreen(RenameScreenRequest request) throws CmuxException {
        Object result = execute(Commands.RENAME_SCREEN, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult renameSurface(RenameSurfaceRequest request) throws CmuxException {
        Object result = execute(Commands.RENAME_SURFACE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final WorkspaceMutationResult renameWorkspace(RenameWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.RENAME_WORKSPACE, request.toWire());
        return WorkspaceMutationResult.fromWire(result);
    }

    public final ReportAgentResult reportAgent(ReportAgentRequest request) throws CmuxException {
        Object result = execute(Commands.REPORT_AGENT, request.toWire());
        return ReportAgentResult.fromWire(result);
    }

    public final EmptyResult reportFocus(ReportFocusRequest request) throws CmuxException {
        Object result = execute(Commands.REPORT_FOCUS, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final AttachedViewResizeResult resizeAttachedView(ResizeAttachedViewRequest request) throws CmuxException {
        Object result = execute(Commands.RESIZE_ATTACHED_VIEW, request.toWire());
        return AttachedViewResizeResult.fromWire(result);
    }

    public final ResizeSurfaceResult resizeSurface(ResizeSurfaceRequest request) throws CmuxException {
        Object result = execute(Commands.RESIZE_SURFACE, request.toWire());
        return ResizeSurfaceResult.fromWire(result);
    }

    public final ResolveTerminalResult resolveTerminal(ResolveTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.RESOLVE_TERMINAL, request.toWire());
        return ResolveTerminalResult.fromWire(result);
    }

    public final RunResult run(RunRequest request) throws CmuxException {
        Object result = execute(Commands.RUN, request.toWire());
        return RunResult.fromWire(result);
    }

    public final EmptyResult scrollSurface(ScrollSurfaceRequest request) throws CmuxException {
        Object result = execute(Commands.SCROLL_SURFACE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult selectScreen(SelectScreenRequest request) throws CmuxException {
        Object result = execute(Commands.SELECT_SCREEN, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult selectTab(SelectTabRequest request) throws CmuxException {
        Object result = execute(Commands.SELECT_TAB, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult selectWorkspace(SelectWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.SELECT_WORKSPACE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult send(SendRequest request) throws CmuxException {
        Object result = execute(Commands.SEND, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult sendKey(SendKeyRequest request) throws CmuxException {
        Object result = execute(Commands.SEND_KEY, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final SetCellPixelsResult setCellPixels(SetCellPixelsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_CELL_PIXELS, request.toWire());
        return SetCellPixelsResult.fromWire(result);
    }

    public final EmptyResult setClientInfo(SetClientInfoRequest request) throws CmuxException {
        Object result = execute(Commands.SET_CLIENT_INFO, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setClientSizing(SetClientSizingRequest request) throws CmuxException {
        Object result = execute(Commands.SET_CLIENT_SIZING, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setDefaultColors(SetDefaultColorsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_DEFAULT_COLORS, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setRatio(SetRatioRequest request) throws CmuxException {
        Object result = execute(Commands.SET_RATIO, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setSplitRatio(SetSplitRatioRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SPLIT_RATIO, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setViewportPaneWidth(SetViewportPaneWidthRequest request) throws CmuxException {
        Object result = execute(Commands.SET_VIEWPORT_PANE_WIDTH, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setWindowTitle(SetWindowTitleRequest request) throws CmuxException {
        Object result = execute(Commands.SET_WINDOW_TITLE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final ShutdownDaemonResult shutdownDaemon(ShutdownDaemonRequest request) throws CmuxException {
        Object result = execute(Commands.SHUTDOWN_DAEMON, request.toWire());
        return ShutdownDaemonResult.fromWire(result);
    }

    public final SidebarPluginResult sidebarPlugin(SidebarPluginRequest request) throws CmuxException {
        Object result = execute(Commands.SIDEBAR_PLUGIN, request.toWire());
        return SidebarPluginResult.fromWire(result);
    }

    public final SurfaceResult split(SplitRequest request) throws CmuxException {
        Object result = execute(Commands.SPLIT, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final CmuxStream<ProtocolEvent> subscribe(SubscribeRequest request) throws CmuxException {
        return openStream(Commands.SUBSCRIBE, request.toWire());
    }

    public final EmptyResult swapPane(SwapPaneRequest request) throws CmuxException {
        Object result = execute(Commands.SWAP_PANE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final TerminalEventsResult terminalEvents(TerminalEventsRequest request) throws CmuxException {
        Object result = execute(Commands.TERMINAL_EVENTS, request.toWire());
        return TerminalEventsResult.fromWire(result);
    }

    public final LayoutUndoResult undoLayout(UndoLayoutRequest request) throws CmuxException {
        Object result = execute(Commands.UNDO_LAYOUT, request.toWire());
        return LayoutUndoResult.fromWire(result);
    }

    public final BrowserProviderUnregisterResult unregisterBrowserProvider() throws CmuxException {
        Object result = execute(Commands.UNREGISTER_BROWSER_PROVIDER, Map.of());
        return BrowserProviderUnregisterResult.fromWire(result);
    }

    public final VtStateResult vtState(VtStateRequest request) throws CmuxException {
        Object result = execute(Commands.VT_STATE, request.toWire());
        return VtStateResult.fromWire(result);
    }

    public final WaitForResult waitFor(WaitForRequest request) throws CmuxException {
        Object result = execute(Commands.WAIT_FOR, request.toWire());
        return WaitForResult.fromWire(result);
    }

    public final ZoomPaneResult zoomPane(ZoomPaneRequest request) throws CmuxException {
        Object result = execute(Commands.ZOOM_PANE, request.toWire());
        return ZoomPaneResult.fromWire(result);
    }

}
