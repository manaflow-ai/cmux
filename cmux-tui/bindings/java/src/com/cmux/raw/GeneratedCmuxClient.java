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

    public final Object ackTabNotifications(AckTabNotificationsRequest request) throws CmuxException {
        Object result = execute(Commands.ACK_TAB_NOTIFICATIONS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object addScreensToScreenGroup(AddScreensToScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.ADD_SCREENS_TO_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object addTabsToTabGroup(AddTabsToTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.ADD_TABS_TO_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

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

    public final Object closeScreenGroup(CloseScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final EmptyResult closeSurface(CloseSurfaceRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_SURFACE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object closeTabGroup(CloseTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object closeTabs(CloseTabsRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_TABS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final CloseTerminalResult closeTerminal(CloseTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_TERMINAL, request.toWire());
        return CloseTerminalResult.fromWire(result);
    }

    public final WorkspaceMutationResult closeWorkspace(CloseWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.CLOSE_WORKSPACE, request.toWire());
        return WorkspaceMutationResult.fromWire(result);
    }

    public final Object conversationAgentToken(ConversationAgentTokenRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_AGENT_TOKEN, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationBind(ConversationBindRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_BIND, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationCreate(ConversationCreateRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_CREATE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationHistory(ConversationHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_HISTORY, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationList() throws CmuxException {
        Object result = execute(Commands.CONVERSATION_LIST, Map.of());
        return Wire.immutableJson(result);
    }

    public final Object conversationOp(ConversationOpRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_OP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationSearch(ConversationSearchRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_SEARCH, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationSnapshot(ConversationSnapshotRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_SNAPSHOT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object conversationTyping(ConversationTypingRequest request) throws CmuxException {
        Object result = execute(Commands.CONVERSATION_TYPING, request.toWire());
        return Wire.immutableJson(result);
    }

    public final CopyResult copy(CopyRequest request) throws CmuxException {
        Object result = execute(Commands.COPY, request.toWire());
        return CopyResult.fromWire(result);
    }

    public final Object createBookmark(CreateBookmarkRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_BOOKMARK, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createBrowserProfile(CreateBrowserProfileRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_BROWSER_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createPersonalGroup(CreatePersonalGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_PERSONAL_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createProfile(CreateProfileRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createScreenGroup(CreateScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createSurfaceWithReceipt(CreateSurfaceWithReceiptRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_SURFACE_WITH_RECEIPT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object createTabGroup(CreateTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_TAB_GROUP, request.toWire());
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

    public final Object createWorkspaceGroup(CreateWorkspaceGroupRequest request) throws CmuxException {
        Object result = execute(Commands.CREATE_WORKSPACE_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteBookmark(DeleteBookmarkRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_BOOKMARK, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteBrowserProfile(DeleteBrowserProfileRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_BROWSER_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deletePersonalGroup(DeletePersonalGroupRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_PERSONAL_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteProfile(DeleteProfileRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteSavedScreenGroup(DeleteSavedScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_SAVED_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteSavedTabGroup(DeleteSavedTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_SAVED_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object deleteWorkspaceGroup(DeleteWorkspaceGroupRequest request) throws CmuxException {
        Object result = execute(Commands.DELETE_WORKSPACE_GROUP, request.toWire());
        return Wire.immutableJson(result);
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

    public final Object feedLocalHandoffAbort(FeedLocalHandoffAbortRequest request) throws CmuxException {
        Object result = execute(Commands.FEED_LOCAL_HANDOFF_ABORT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object feedLocalHandoffBegin(FeedLocalHandoffBeginRequest request) throws CmuxException {
        Object result = execute(Commands.FEED_LOCAL_HANDOFF_BEGIN, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object feedLocalHandoffDone(FeedLocalHandoffDoneRequest request) throws CmuxException {
        Object result = execute(Commands.FEED_LOCAL_HANDOFF_DONE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object feedLocalList(FeedLocalListRequest request) throws CmuxException {
        Object result = execute(Commands.FEED_LOCAL_LIST, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object feedLocalRead(FeedLocalReadRequest request) throws CmuxException {
        Object result = execute(Commands.FEED_LOCAL_READ, request.toWire());
        return Wire.immutableJson(result);
    }

    public final FocusDirectionResult focusDirection(FocusDirectionRequest request) throws CmuxException {
        Object result = execute(Commands.FOCUS_DIRECTION, request.toWire());
        return FocusDirectionResult.fromWire(result);
    }

    public final EmptyResult focusPane(FocusPaneRequest request) throws CmuxException {
        Object result = execute(Commands.FOCUS_PANE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object forgetSession(ForgetSessionRequest request) throws CmuxException {
        Object result = execute(Commands.FORGET_SESSION, request.toWire());
        return Wire.immutableJson(result);
    }

    public final BrowserProviderSnapshot getBrowserProvider() throws CmuxException {
        Object result = execute(Commands.GET_BROWSER_PROVIDER, Map.of());
        return BrowserProviderSnapshot.fromWire(result);
    }

    public final GetCellPixelsResult getCellPixels() throws CmuxException {
        Object result = execute(Commands.GET_CELL_PIXELS, Map.of());
        return GetCellPixelsResult.fromWire(result);
    }

    public final Object getFrontendBrowserHistory(GetFrontendBrowserHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.GET_FRONTEND_BROWSER_HISTORY, request.toWire());
        return Wire.immutableJson(result);
    }

    public final FrontendProjection getFrontendProjection(GetFrontendProjectionRequest request) throws CmuxException {
        Object result = execute(Commands.GET_FRONTEND_PROJECTION, request.toWire());
        return FrontendProjection.fromWire(result);
    }

    public final GetSizeStateResult getSizeState(GetSizeStateRequest request) throws CmuxException {
        Object result = execute(Commands.GET_SIZE_STATE, request.toWire());
        return GetSizeStateResult.fromWire(result);
    }

    public final IdentifyResult identify() throws CmuxException {
        Object result = execute(Commands.IDENTIFY, Map.of());
        return IdentifyResult.fromWire(result);
    }

    public final IdsResult ids(IdsRequest request) throws CmuxException {
        Object result = execute(Commands.IDS, request.toWire());
        return IdsResult.fromWire(result);
    }

    public final Object importBookmarks(ImportBookmarksRequest request) throws CmuxException {
        Object result = execute(Commands.IMPORT_BOOKMARKS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object importSessionOrganization(ImportSessionOrganizationRequest request) throws CmuxException {
        Object result = execute(Commands.IMPORT_SESSION_ORGANIZATION, request.toWire());
        return Wire.immutableJson(result);
    }

    public final JournalFrontendEventResult journalFrontendEvent(JournalFrontendEventRequest request) throws CmuxException {
        Object result = execute(Commands.JOURNAL_FRONTEND_EVENT, request.toWire());
        return JournalFrontendEventResult.fromWire(result);
    }

    public final ListAgentsResult listAgents(ListAgentsRequest request) throws CmuxException {
        Object result = execute(Commands.LIST_AGENTS, request.toWire());
        return ListAgentsResult.fromWire(result);
    }

    public final Object listBookmarks(ListBookmarksRequest request) throws CmuxException {
        Object result = execute(Commands.LIST_BOOKMARKS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final List<ClientInfo> listClients() throws CmuxException {
        Object result = execute(Commands.LIST_CLIENTS, Map.of());
        return Wire.array(result, "list-clients result", item -> ClientInfo.fromWire(item));
    }

    public final Object listNotifications(ListNotificationsRequest request) throws CmuxException {
        Object result = execute(Commands.LIST_NOTIFICATIONS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object listPersonal() throws CmuxException {
        Object result = execute(Commands.LIST_PERSONAL, Map.of());
        return Wire.immutableJson(result);
    }

    public final Object listSavedScreenGroups() throws CmuxException {
        Object result = execute(Commands.LIST_SAVED_SCREEN_GROUPS, Map.of());
        return Wire.immutableJson(result);
    }

    public final Object listSavedTabGroups() throws CmuxException {
        Object result = execute(Commands.LIST_SAVED_TAB_GROUPS, Map.of());
        return Wire.immutableJson(result);
    }

    public final Object listTabGroups() throws CmuxException {
        Object result = execute(Commands.LIST_TAB_GROUPS, Map.of());
        return Wire.immutableJson(result);
    }

    public final ListTerminalsResult listTerminals() throws CmuxException {
        Object result = execute(Commands.LIST_TERMINALS, Map.of());
        return ListTerminalsResult.fromWire(result);
    }

    public final Object listWorkspaceGroups() throws CmuxException {
        Object result = execute(Commands.LIST_WORKSPACE_GROUPS, Map.of());
        return Wire.immutableJson(result);
    }

    public final Tree listWorkspaces() throws CmuxException {
        Object result = execute(Commands.LIST_WORKSPACES, Map.of());
        return Tree.fromWire(result);
    }

    public final MachineListeningTcpResult machineListeningTcp() throws CmuxException {
        Object result = execute(Commands.MACHINE_LISTENING_TCP, Map.of());
        return MachineListeningTcpResult.fromWire(result);
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

    public final Object moveBookmark(MoveBookmarkRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_BOOKMARK, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveBrowserProfile(MoveBrowserProfileRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_BROWSER_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object movePersonalGroup(MovePersonalGroupRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_PERSONAL_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveProfile(MoveProfileRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveScreen(MoveScreenRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_SCREEN, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveScreenGroup(MoveScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final EmptyResult moveTab(MoveTabRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object moveTabGroup(MoveTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabGroupToColumn(MoveTabGroupToColumnRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_GROUP_TO_COLUMN, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabGroupToNewWorkspace(MoveTabGroupToNewWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_GROUP_TO_NEW_WORKSPACE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabGroupToSplit(MoveTabGroupToSplitRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_GROUP_TO_SPLIT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabToColumn(MoveTabToColumnRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_TO_COLUMN, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabToNewWorkspace(MoveTabToNewWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_TO_NEW_WORKSPACE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveTabToSplit(MoveTabToSplitRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_TO_SPLIT, request.toWire());
        return Wire.immutableJson(result);
    }

    public final EmptyResult moveTabToWorkspace(MoveTabToWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_TAB_TO_WORKSPACE, request.toWire());
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

    public final Object moveWorkspaceGroup(MoveWorkspaceGroupRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_WORKSPACE_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object moveWorkspaceToGroup(MoveWorkspaceToGroupRequest request) throws CmuxException {
        Object result = execute(Commands.MOVE_WORKSPACE_TO_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final SurfaceResult newBrowserTab(NewBrowserTabRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_BROWSER_TAB, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final Object newConversationTab(NewConversationTabRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_CONVERSATION_TAB, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object newFrontendBrowserTab(NewFrontendBrowserTabRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_FRONTEND_BROWSER_TAB, request.toWire());
        return Wire.immutableJson(result);
    }

    public final SurfaceResult newPane(NewPaneRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_PANE, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final SurfaceResult newPaneRight(NewPaneRightRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_PANE_RIGHT, request.toWire());
        return SurfaceResult.fromWire(result);
    }

    public final NewRowResult newRow(NewRowRequest request) throws CmuxException {
        Object result = execute(Commands.NEW_ROW, request.toWire());
        return NewRowResult.fromWire(result);
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

    public final NoteSizeActivityResult noteSizeActivity(NoteSizeActivityRequest request) throws CmuxException {
        Object result = execute(Commands.NOTE_SIZE_ACTIVITY, request.toWire());
        return NoteSizeActivityResult.fromWire(result);
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

    public final PasteImageResult pasteImage(PasteImageRequest request) throws CmuxException {
        Object result = execute(Commands.PASTE_IMAGE, request.toWire());
        return PasteImageResult.fromWire(result);
    }

    public final Object pinWorkspace(PinWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.PIN_WORKSPACE, request.toWire());
        return Wire.immutableJson(result);
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

    public final Object putSession(PutSessionRequest request) throws CmuxException {
        Object result = execute(Commands.PUT_SESSION, request.toWire());
        return Wire.immutableJson(result);
    }

    public final ReadScreenResult readScreen(ReadScreenRequest request) throws CmuxException {
        Object result = execute(Commands.READ_SCREEN, request.toWire());
        return ReadScreenResult.fromWire(result);
    }

    public final ReadScrollbackResult readScrollback(ReadScrollbackRequest request) throws CmuxException {
        Object result = execute(Commands.READ_SCROLLBACK, request.toWire());
        return ReadScrollbackResult.fromWire(result);
    }

    public final ReattachViewResult reattachView(ReattachViewRequest request) throws CmuxException {
        Object result = execute(Commands.REATTACH_VIEW, request.toWire());
        return ReattachViewResult.fromWire(result);
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

    public final Object removeScreensFromScreenGroup(RemoveScreensFromScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.REMOVE_SCREENS_FROM_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object removeTabsFromTabGroup(RemoveTabsFromTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.REMOVE_TABS_FROM_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
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

    public final Object reopenSavedScreenGroup(ReopenSavedScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.REOPEN_SAVED_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object reopenSavedTabGroup(ReopenSavedTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.REOPEN_SAVED_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
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

    public final Object saveScreenGroup(SaveScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.SAVE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object saveTabGroup(SaveTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.SAVE_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
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

    public final ServerStatsResult serverStats() throws CmuxException {
        Object result = execute(Commands.SERVER_STATS, Map.of());
        return ServerStatsResult.fromWire(result);
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

    public final Object setColumnSticky(SetColumnStickyRequest request) throws CmuxException {
        Object result = execute(Commands.SET_COLUMN_STICKY, request.toWire());
        return Wire.immutableJson(result);
    }

    public final EmptyResult setDefaultColors(SetDefaultColorsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_DEFAULT_COLORS, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object setFrontendBrowserHistory(SetFrontendBrowserHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.SET_FRONTEND_BROWSER_HISTORY, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object setPersonalTerminal(SetPersonalTerminalRequest request) throws CmuxException {
        Object result = execute(Commands.SET_PERSONAL_TERMINAL, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object setPersonalWorkspace(SetPersonalWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.SET_PERSONAL_WORKSPACE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object setProfileFollows(SetProfileFollowsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_PROFILE_FOLLOWS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final EmptyResult setRatio(SetRatioRequest request) throws CmuxException {
        Object result = execute(Commands.SET_RATIO, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object setRowHeights(SetRowHeightsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_ROW_HEIGHTS, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object setScreenMetadata(SetScreenMetadataRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SCREEN_METADATA, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object setScreenPinned(SetScreenPinnedRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SCREEN_PINNED, request.toWire());
        return Wire.immutableJson(result);
    }

    public final SetSizeCountsResult setSizeCounts(SetSizeCountsRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SIZE_COUNTS, request.toWire());
        return SetSizeCountsResult.fromWire(result);
    }

    public final SetSizePolicyResult setSizePolicy(SetSizePolicyRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SIZE_POLICY, request.toWire());
        return SetSizePolicyResult.fromWire(result);
    }

    public final EmptyResult setSplitRatio(SetSplitRatioRequest request) throws CmuxException {
        Object result = execute(Commands.SET_SPLIT_RATIO, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object setTabPinned(SetTabPinnedRequest request) throws CmuxException {
        Object result = execute(Commands.SET_TAB_PINNED, request.toWire());
        return Wire.immutableJson(result);
    }

    public final TerminalCommandHistoryResult setTerminalCommandHistory(SetTerminalCommandHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.SET_TERMINAL_COMMAND_HISTORY, request.toWire());
        return TerminalCommandHistoryResult.fromWire(result);
    }

    public final SetTerminalIdlePolicyResult setTerminalIdlePolicy(SetTerminalIdlePolicyRequest request) throws CmuxException {
        Object result = execute(Commands.SET_TERMINAL_IDLE_POLICY, request.toWire());
        return SetTerminalIdlePolicyResult.fromWire(result);
    }

    public final SetTerminalKeepResult setTerminalKeep(SetTerminalKeepRequest request) throws CmuxException {
        Object result = execute(Commands.SET_TERMINAL_KEEP, request.toWire());
        return SetTerminalKeepResult.fromWire(result);
    }

    public final EmptyResult setViewportPaneWidth(SetViewportPaneWidthRequest request) throws CmuxException {
        Object result = execute(Commands.SET_VIEWPORT_PANE_WIDTH, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final EmptyResult setWindowTitle(SetWindowTitleRequest request) throws CmuxException {
        Object result = execute(Commands.SET_WINDOW_TITLE, request.toWire());
        return EmptyResult.fromWire(result);
    }

    public final Object setWorkspaceMetadata(SetWorkspaceMetadataRequest request) throws CmuxException {
        Object result = execute(Commands.SET_WORKSPACE_METADATA, request.toWire());
        return Wire.immutableJson(result);
    }

    public final ShutdownDaemonResult shutdownDaemon(ShutdownDaemonRequest request) throws CmuxException {
        Object result = execute(Commands.SHUTDOWN_DAEMON, request.toWire());
        return ShutdownDaemonResult.fromWire(result);
    }

    public final SidebarPluginResult sidebarPlugin(SidebarPluginRequest request) throws CmuxException {
        Object result = execute(Commands.SIDEBAR_PLUGIN, request.toWire());
        return SidebarPluginResult.fromWire(result);
    }

    public final SnapshotRequestResult snapshotRequest(SnapshotRequestRequest request) throws CmuxException {
        Object result = execute(Commands.SNAPSHOT_REQUEST, request.toWire());
        return SnapshotRequestResult.fromWire(result);
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

    public final TerminalHistoryPagesResult terminalHistory(TerminalHistoryRequest request) throws CmuxException {
        Object result = execute(Commands.TERMINAL_HISTORY, request.toWire());
        return TerminalHistoryPagesResult.fromWire(result);
    }

    public final TerminalReadRangeResult terminalReadRange(TerminalReadRangeRequest request) throws CmuxException {
        Object result = execute(Commands.TERMINAL_READ_RANGE, request.toWire());
        return TerminalReadRangeResult.fromWire(result);
    }

    public final TerminalResourcesResult terminalResources(TerminalResourcesRequest request) throws CmuxException {
        Object result = execute(Commands.TERMINAL_RESOURCES, request.toWire());
        return TerminalResourcesResult.fromWire(result);
    }

    public final LayoutUndoResult undoLayout(UndoLayoutRequest request) throws CmuxException {
        Object result = execute(Commands.UNDO_LAYOUT, request.toWire());
        return LayoutUndoResult.fromWire(result);
    }

    public final Object ungroupScreenGroup(UngroupScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UNGROUP_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object ungroupTabGroup(UngroupTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UNGROUP_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object unpinWorkspace(UnpinWorkspaceRequest request) throws CmuxException {
        Object result = execute(Commands.UNPIN_WORKSPACE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final BrowserProviderUnregisterResult unregisterBrowserProvider() throws CmuxException {
        Object result = execute(Commands.UNREGISTER_BROWSER_PROVIDER, Map.of());
        return BrowserProviderUnregisterResult.fromWire(result);
    }

    public final Object unsaveScreenGroup(UnsaveScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UNSAVE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object unsaveTabGroup(UnsaveTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UNSAVE_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateBookmark(UpdateBookmarkRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_BOOKMARK, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateBrowserProfile(UpdateBrowserProfileRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_BROWSER_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateFrontendBrowserTab(UpdateFrontendBrowserTabRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_FRONTEND_BROWSER_TAB, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updatePersonalGroup(UpdatePersonalGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_PERSONAL_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateProfile(UpdateProfileRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_PROFILE, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateScreenGroup(UpdateScreenGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_SCREEN_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateTabGroup(UpdateTabGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_TAB_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final Object updateWorkspaceGroup(UpdateWorkspaceGroupRequest request) throws CmuxException {
        Object result = execute(Commands.UPDATE_WORKSPACE_GROUP, request.toWire());
        return Wire.immutableJson(result);
    }

    public final GuestUrlOpenResult urlOpen(UrlOpenRequest request) throws CmuxException {
        Object result = execute(Commands.URL_OPEN, request.toWire());
        return GuestUrlOpenResult.fromWire(result);
    }

    public final GuestUrlClaimResult urlOpenClaim(UrlOpenClaimRequest request) throws CmuxException {
        Object result = execute(Commands.URL_OPEN_CLAIM, request.toWire());
        return GuestUrlClaimResult.fromWire(result);
    }

    public final GuestUrlAcknowledgeResult urlOpenResult(UrlOpenResultRequest request) throws CmuxException {
        Object result = execute(Commands.URL_OPEN_RESULT, request.toWire());
        return GuestUrlAcknowledgeResult.fromWire(result);
    }

    public final CmuxStream<ProtocolEvent> urlOpenSubscribe(UrlOpenSubscribeRequest request) throws CmuxException {
        return openStream(Commands.URL_OPEN_SUBSCRIBE, request.toWire());
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
