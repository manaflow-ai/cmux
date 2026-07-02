import AppKit
import CMUXMobileCore
import CmuxControlSocket
import CmuxWindowing
import CmuxWorkspaces
import Foundation

/// Mobile workspace-list RPC entrypoints on the data-plane god object.
///
/// The list/close/group-collapse dispatch logic now lives in
/// ``MobileWorkspaceListRPCHandler``; this file is the thin seam between it and
/// ``TerminalController``: the handler reaches the terminal data plane (param
/// coercion, tab-manager / window resolution, notification store, terminal
/// panels, and the localized close-blocked message) only through the
/// ``MobileWorkspaceListRPCHost`` conformance below, and the entrypoints other
/// callers still drive (the mobile data-plane RPC, the create / terminal-create
/// echo paths, and the workspace-list fidelity tests) forward to the owned
/// handler. The phone shows workspaces from every open Mac window; serialization
/// and the iMessage-style activity preview are identical to before the move.
extension TerminalController {
    /// The owned mobile workspace-list dispatch handler. Built lazily so it
    /// captures `self` as its host seam after the controller is fully
    /// constructed; the notification store it reads is resolved through the seam
    /// at call time.
    var mobileWorkspaceListHandler: MobileWorkspaceListRPCHandler {
        if let existing = mobileWorkspaceListHandlerStorage {
            return existing
        }
        let handler = MobileWorkspaceListRPCHandler(host: self)
        mobileWorkspaceListHandlerStorage = handler
        return handler
    }

    /// Mobile-gated collapse/expand of a workspace group. Forwards to the owned
    /// handler; see ``MobileWorkspaceListRPCHandler/setGroupCollapsed(params:isCollapsed:)``.
    func v2MobileWorkspaceGroupSetCollapsed(params: [String: Any], isCollapsed: Bool) -> V2CallResult {
        mobileWorkspaceListHandler.setGroupCollapsed(params: params, isCollapsed: isCollapsed)
    }

    /// The iOS-facing workspace/terminal list. Forwards to the owned handler;
    /// the mobile data-plane RPC and the create / terminal-create echo paths
    /// drive this with an explicit `tabManager` and created ids, so the
    /// signature is preserved. See
    /// ``MobileWorkspaceListRPCHandler/list(params:tabManager:createdWorkspaceID:createdTerminalID:)``.
    func v2MobileWorkspaceList(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        createdWorkspaceID: String? = nil,
        createdTerminalID: String? = nil
    ) -> V2CallResult {
        mobileWorkspaceListHandler.list(
            params: params,
            tabManager: resolvedTabManager,
            createdWorkspaceID: createdWorkspaceID,
            createdTerminalID: createdTerminalID
        )
    }

    /// Serializes one workspace into the iOS-facing mobile list shape. Forwards
    /// to the owned handler; the workspace-list fidelity tests drive this
    /// directly. See
    /// ``MobileWorkspaceListRPCHandler/mobileWorkspacePayload(workspace:windowID:isSelected:requestedTerminalID:notificationStore:)``.
    func mobileWorkspacePayload(
        workspace: Workspace,
        windowID: UUID? = nil,
        isSelected: Bool,
        requestedTerminalID: UUID?,
        notificationStore: TerminalNotificationStore? = nil
    ) -> [String: Any] {
        mobileWorkspaceListHandler.mobileWorkspacePayload(
            workspace: workspace,
            windowID: windowID,
            isSelected: isSelected,
            requestedTerminalID: requestedTerminalID,
            notificationStore: notificationStore
        )
    }

    /// Mobile-gated close of one explicit workspace. Forwards to the owned
    /// handler; see ``MobileWorkspaceListRPCHandler/close(params:)``.
    func v2MobileWorkspaceClose(params: [String: Any]) -> V2CallResult {
        mobileWorkspaceListHandler.close(params: params)
    }

    /// Maximum characters in a mobile workspace preview line. Re-exported from
    /// the owned handler for the workspace-list fidelity tests.
    nonisolated static var mobilePreviewMaxLength: Int { MobileWorkspaceListRPCHandler.mobilePreviewMaxLength }

    /// How much raw notification text the preview sanitizer scans. Re-exported
    /// from the owned handler for the workspace-list fidelity tests.
    nonisolated static var mobilePreviewInputCap: Int { MobileWorkspaceListRPCHandler.mobilePreviewInputCap }

    /// Flattens arbitrary notification text into a single plain-text preview
    /// line. Re-exported from the owned handler for the workspace-list fidelity
    /// tests. See ``MobileWorkspaceListRPCHandler/mobilePreviewSanitize(_:)``.
    nonisolated static func mobilePreviewSanitize(_ raw: String) -> String? {
        MobileWorkspaceListRPCHandler.mobilePreviewSanitize(raw)
    }
}

// MARK: - MobileWorkspaceListRPCHost

extension TerminalController: MobileWorkspaceListRPCHost {
    func mobileWorkspaceListHasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        v2HasNonNullParam(params, key)
    }

    func mobileWorkspaceListUUID(_ params: [String: Any], _ key: String) -> UUID? {
        v2UUID(params, key)
    }

    func mobileWorkspaceListTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        mobileTerminalAliasUUID(params: params)
    }

    func mobileWorkspaceListResolveTabManager(params: [String: Any]) -> TabManager? {
        v2ResolveTabManager(params: params)
    }

    func mobileWorkspaceListResolveWindowId(tabManager: TabManager?) -> UUID? {
        v2ResolveWindowId(tabManager: tabManager)
    }

    var mobileWorkspaceListKeyWindowSelectedWorkspaceID: UUID? {
        appEnvironment?.windowRegistry.currentScriptableMainWindow()?.tabManager.selectedTabId
    }

    var mobileWorkspaceListAppAvailable: Bool {
        // Keyed on the same source the sibling witnesses read
        // (mobileWorkspaceListMainWindowSummaries/TabManager/NotificationStore all
        // resolve through appEnvironment), so the availability gate can never
        // disagree with the data reads.
        appEnvironment != nil
    }

    func mobileWorkspaceListMainWindowSummaries() -> [MainWindowSummary] {
        appEnvironment?.windowRegistry.listMainWindowSummaries() ?? []
    }

    func mobileWorkspaceListTabManager(windowId: UUID) -> TabManager? {
        appEnvironment?.windowRegistry.tabManagerFor(windowId: windowId)
    }

    func mobileWorkspaceListMainSync<T>(_ body: @MainActor () -> T) -> T {
        v2MainSync(body)
    }

    func mobileWorkspaceListOrNull(_ value: Any?) -> Any {
        v2OrNull(value)
    }

    func mobileWorkspaceListRef(kind: ControlHandleKind, uuid: UUID?) -> Any {
        v2Ref(kind: kind, uuid: uuid)
    }

    func mobileWorkspaceListNonEmpty(_ raw: String?) -> String? {
        mobileNonEmpty(raw)
    }

    func mobileWorkspaceListTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        mobileTerminalPanels(in: workspace)
    }

    func mobileWorkspaceListAdoptDetectedAgentSessions(workspace: Workspace) {
        adoptDetectedAgentSessions(workspace: workspace)
    }

    var mobileWorkspaceListNotificationStore: TerminalNotificationStore? {
        appEnvironment?.notificationStore
    }

    var mobileWorkspaceListCloseBlockedMessage: String {
        String(
            localized: "workspace.closeBlocked.message",
            defaultValue: "This workspace can't be closed right now."
        )
    }
}
