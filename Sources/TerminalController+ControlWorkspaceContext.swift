import CmuxControlSocket
import CmuxCore
import CmuxPanes
import CmuxWorkspaces
import Foundation

/// The workspace-domain witnesses for the stage-3c ``ControlCommandCoordinator``:
/// the byte-faithful bodies of the former non-group `v2Workspace*` dispatchers,
/// minus the per-read `v2MainSync` hop (the coordinator already runs on the main
/// actor inside the socket-command policy scope, so each hop would re-apply the
/// identical thread-local focus-allowance stack — a no-op). TabManager
/// resolution goes through the shared `resolveTabManager(routing:)` and the
/// workspace-owner-first resolutions the legacy bodies used; app structs are
/// converted to the package's Sendable snapshots, and app-typed payloads (the
/// `remoteStatusPayload()` object) are bridged to ``JSONValue``.
///
/// `workspace.group.*` lives in `TerminalController+ControlWorkspaceGroupContext`;
/// `workspace.action` / `extension.sidebar.snapshot` and the worker-lane
/// `workspace.remote.pty_*` (sessions/close/detach/bridge/resize) methods stay on
/// the app-side dispatcher.
extension TerminalController: ControlWorkspaceContext {
    func controlWorkspaceStrings() -> ControlWorkspaceStrings {
        ControlWorkspaceStrings(
            closeProtected: String(
                localized: "workspace.closeProtected.message",
                defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
            ),
            reorderManyMissingOrder: String(
                localized: "socket.workspace.reorderMany.missingOrder",
                defaultValue: "Missing workspace_ids"
            ),
            reorderManyDuplicateWorkspace: String(
                localized: "socket.workspace.reorderMany.duplicateWorkspace",
                defaultValue: "Duplicate workspace in order"
            ),
            reorderManyWorkspaceNotFound: String(
                localized: "socket.workspace.reorderMany.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            reorderManyInvalidWorkspace: String(
                localized: "socket.workspace.reorderMany.invalidWorkspace",
                defaultValue: "Invalid workspace id or ref"
            ),
            reorderManyTabManagerUnavailable: String(
                localized: "socket.workspace.reorderMany.tabManagerUnavailable",
                defaultValue: "TabManager not available"
            )
        )
    }

    func controlWorkspaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    // MARK: - Snapshots

    /// Builds the Sendable summary of one workspace (the legacy
    /// `v2WorkspaceSummaryPayload` data, minus the index/selected/ref minting the
    /// coordinator now owns), bridging the app-typed `remoteStatusPayload()`.
    private func controlWorkspaceSummary(_ workspace: Workspace) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: workspace.id, title: workspace.title, customTitle: workspace.customTitle,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            listeningPorts: workspace.listeningPorts,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:]),
            currentDirectory: workspace.presentedCurrentDirectory ?? "",
            customColor: workspace.customColor,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt.map(CmuxEventBus.isoTimestamp)
        )
    }

    // MARK: - List / current

    func controlWorkspaceList(routing: ControlRoutingSelectors) -> ControlWorkspaceListResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let selectedId = tabManager.selectedTabId
        var selectedIndex: Int?
        let summaries = tabManager.tabs.enumerated().map { index, ws -> ControlWorkspaceSummary in
            if ws.id == selectedId {
                selectedIndex = index
            }
            return controlWorkspaceSummary(ws)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(windowID: windowId, workspaces: summaries, selectedIndex: selectedIndex)
    }

    func controlWorkspaceCurrent(routing: ControlRoutingSelectors) -> ControlWorkspaceCurrentResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let workspaceId = tabManager.selectedTabId else {
            return .noWorkspaceSelected
        }
        // Legacy: a selectedTabId pointing at a workspace missing from `tabs`
        // still answered .ok with "workspace": null.
        let workspace = tabManager.tabs.first(where: { $0.id == workspaceId })
        let index = tabManager.tabs.firstIndex(where: { $0.id == workspaceId })
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            workspaceID: workspaceId,
            index: index,
            summary: workspace.map { controlWorkspaceSummary($0) }
        )
    }

    // MARK: - Create

    /// `workspace.create` forwards to the single shared `v2WorkspaceCreate` body
    /// (also driven by `v2MobileWorkspaceCreate`), bridging its Foundation result
    /// — one source of truth for the create logic, byte-identical wire output.
    func controlWorkspaceCreate(params: [String: JSONValue]) -> ControlCallResult {
        switch v2WorkspaceCreate(params: params.mapValues(\.foundationObject)) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - Select / close / move

    func controlSelectWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceRoutedResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound
        }
        // If this workspace belongs to another window, bring it forward so focus
        // is visible.
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        if let windowId {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        tabManager.selectWorkspace(ws)
        return .resolved(windowID: windowId)
    }

    func controlCloseWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceCloseResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        guard let ws = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound
        }
        guard tabManager.canCloseWorkspace(ws) else {
            return .protected(windowID: windowId)
        }
        tabManager.closeWorkspace(ws)
        return .resolved(windowID: windowId)
    }

    func controlMoveWorkspaceToWindow(
        workspaceID: UUID,
        windowID: UUID,
        focusRequested: Bool
    ) -> ControlWorkspaceMoveToWindowResolution {
        guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else {
            return .workspaceNotFound
        }
        guard let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowID) else {
            return .windowNotFound
        }
        guard let ws = srcTM.detachWorkspace(tabId: workspaceID) else {
            return .workspaceNotFound
        }
        let focus = v2FocusAllowed(requested: focusRequested)
        dstTM.attachWorkspace(ws, select: focus)
        if focus {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(dstTM)
        }
        return .resolved
    }

    // MARK: - Reorder

    func controlReorderWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        toIndex: Int?,
        beforeWorkspaceID: UUID?,
        afterWorkspaceID: UUID?,
        dryRun: Bool
    ) -> ControlWorkspaceReorderResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            // The coordinator already confirmed routing resolves a TabManager,
            // so this only fails if the window vanished between calls; treat as
            // not-found to match the legacy outcome.
            return .notFound
        }
        let plan: WorkspaceReorderPlanItem?
        if let toIndex {
            plan = tabManager.workspaceReorderPlan(tabId: workspaceID, toIndex: toIndex)
        } else {
            plan = tabManager.workspaceReorderPlan(
                tabId: workspaceID,
                before: beforeWorkspaceID,
                after: afterWorkspaceID
            )
        }
        guard let plan else {
            return .notFound
        }
        if !dryRun {
            _ = tabManager.reorderWorkspace(tabId: workspaceID, toIndex: plan.toIndex)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            plan: ControlWorkspaceReorderPlanItem(
                workspaceID: plan.workspaceId,
                fromIndex: plan.fromIndex,
                toIndex: plan.toIndex
            )
        )
    }

    func controlReorderWorkspacesMany(
        routing: ControlRoutingSelectors,
        workspaceIDs: [UUID],
        dryRun: Bool
    ) -> ControlWorkspaceReorderManyResolution {
        guard let tabManager = resolveReorderManyTabManager(routing: routing, workspaceIDs: workspaceIDs) else {
            return .tabManagerUnavailable
        }
        let result = tabManager.reorderWorkspaces(orderedWorkspaceIds: workspaceIDs, dryRun: dryRun)
        switch result {
        case .success(let planned):
            let windowId = AppDelegate.shared?.windowId(for: tabManager)
            let plans = planned.map {
                ControlWorkspaceReorderPlanItem(
                    workspaceID: $0.workspaceId,
                    fromIndex: $0.fromIndex,
                    toIndex: $0.toIndex
                )
            }
            return .resolved(windowID: windowId, plans: plans)
        case .failure(.duplicateWorkspace(let workspaceId)):
            return .duplicateWorkspace(workspaceId)
        case .failure(.workspaceNotFound(let workspaceId)):
            return .workspaceNotFound(workspaceId)
        }
    }

    /// Mirrors the legacy `v2ResolveWorkspaceReorderManyTabManager`: an explicit
    /// `window_id` wins, otherwise the first owning workspace's TabManager,
    /// otherwise the routing fallback.
    private func resolveReorderManyTabManager(
        routing: ControlRoutingSelectors,
        workspaceIDs: [UUID]
    ) -> TabManager? {
        if routing.hasWindowIDParam {
            return resolveTabManager(routing: routing)
        }
        for workspaceId in workspaceIDs {
            if let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) {
                return owner
            }
        }
        return resolveTabManager(routing: routing)
    }

    // MARK: - Prompt submit / rename

    func controlSubmitWorkspacePrompt(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        message: String?
    ) -> ControlWorkspacePromptSubmitResolution {
        guard let tabManager = (AppDelegate.shared?.tabManagerFor(tabId: workspaceID))
            ?? resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        guard let outcome = tabManager.handlePromptSubmit(
            workspaceId: workspaceID,
            message: message,
            iMessageModeEnabled: iMessageModeEnabled
        ) else {
            return .notFound
        }
        let preview = tabManager.tabs.first(where: { $0.id == workspaceID })?.latestSubmittedMessage
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            iMessageModeEnabled: iMessageModeEnabled,
            messageRecorded: outcome.messageRecorded,
            reordered: outcome.reordered,
            index: outcome.index,
            messagePreview: preview
        )
    }

    func controlRenameWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        title: String
    ) -> ControlWorkspaceRoutedResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard tabManager.tabs.contains(where: { $0.id == workspaceID }) else {
            return .notFound
        }
        tabManager.setCustomTitle(tabId: workspaceID, title: title)
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(windowID: windowId)
    }

    // MARK: - Navigation

    func controlSelectNextWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard tabManager.selectedTabId != nil else { return .notFound }
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        tabManager.selectNextTab()
        guard let workspaceId = tabManager.selectedTabId else { return .notFound }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(workspaceID: workspaceId, windowID: windowId)
    }

    func controlSelectPreviousWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard tabManager.selectedTabId != nil else { return .notFound }
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        tabManager.selectPreviousTab()
        guard let workspaceId = tabManager.selectedTabId else { return .notFound }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(workspaceID: workspaceId, windowID: windowId)
    }

    func controlSelectLastWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let before = tabManager.selectedTabId else { return .notFound }
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        tabManager.navigateBack()
        guard let after = tabManager.selectedTabId, after != before else { return .notFound }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(workspaceID: after, windowID: windowId)
    }

    // MARK: - Equalize

    func controlEqualizeWorkspaceSplits(
        routing: ControlRoutingSelectors,
        orientationFilter: String?
    ) -> ControlWorkspaceEqualizeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .notFound
        }
        let tree = ws.bonsplitController.treeSnapshot()
        let equalizeResult = tabManager.paneLayout.equalizeSplits(
            in: tree,
            controller: ws.bonsplitController,
            orientationFilter: orientationFilter
        )
        return .resolved(workspaceID: ws.id, equalized: equalizeResult.didFullyEqualize)
    }

    /// Mirrors the legacy `v2ResolveWorkspace(params:tabManager:)` precedence
    /// using the pre-resolved routing selectors: workspace, then surface, then
    /// pane (same TabManager), then the selected workspace.
    private func resolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let workspaceId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == workspaceId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID,
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let workspaceId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == workspaceId })
    }

    // MARK: - Remote

    func controlResolveRemoteWorkspaceID(
        routing: ControlRoutingSelectors,
        requestedWorkspaceID: UUID?
    ) -> UUID? {
        let fallbackTabManager = resolveTabManager(routing: routing)
        return requestedWorkspaceID ?? fallbackTabManager?.selectedTabId
    }

    func controlDisconnectWorkspaceRemote(
        workspaceID: UUID,
        clearConfiguration: Bool
    ) -> ControlWorkspaceRemoteResolution {
        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = owner.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound(workspaceID: workspaceID)
        }
        workspace.disconnectRemoteConnection(clearConfiguration: clearConfiguration)
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    func controlReconnectWorkspaceRemote(
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlWorkspaceRemoteResolution {
        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = owner.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound(workspaceID: workspaceID)
        }
        guard workspace.remoteConfiguration != nil else {
            return .notConfigured(workspaceID: workspaceID)
        }
        workspace.reconnectRemoteConnection(surfaceId: surfaceID)
        notifyRemotePTYControllerAvailabilityChanged()
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    func controlWorkspaceRemoteForegroundAuthReady(
        workspaceID: UUID,
        foregroundAuthToken: String?
    ) -> ControlWorkspaceRemoteResolution {
        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = owner.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound(workspaceID: workspaceID)
        }
        workspace.notifyRemoteForegroundAuthenticationReady(token: foregroundAuthToken)
        notifyRemotePTYControllerAvailabilityChanged()
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    func controlWorkspaceRemoteStatus(workspaceID: UUID) -> ControlWorkspaceRemoteResolution {
        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = owner.tabs.first(where: { $0.id == workspaceID }) else {
            return .notFound(workspaceID: workspaceID)
        }
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    func controlWorkspaceRemotePTYAttachEnd(
        workspaceID workspaceId: UUID,
        surfaceID surfaceId: UUID,
        sessionID: String
    ) -> ControlWorkspaceRemotePTYAttachEndResolution {
        let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: surfaceId,
            preferredWorkspaceId: workspaceId
        )
        let fallbackOwner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        let fallbackWorkspace = fallbackOwner?.tabs.first(where: { $0.id == workspaceId })
        guard let owner = located?.tabManager ?? fallbackOwner,
              let workspace = located?.workspace ?? fallbackWorkspace else {
            return .notFound
        }
        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: surfaceId, sessionID: sessionID)
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            clearedRemotePTYSession: outcome.clearedRemotePTYSession,
            untrackedRemoteTerminal: outcome.untrackedRemoteTerminal,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    func controlWorkspaceRemoteTerminalSessionEnd(
        workspaceID workspaceId: UUID,
        surfaceID surfaceId: UUID,
        relayPort: Int
    ) -> ControlWorkspaceRemoteTerminalSessionEndResolution {
        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
            return .notFound
        }
        workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .resolved(
            windowID: windowId,
            workspaceID: workspace.id,
            remoteStatus: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:])
        )
    }

    // MARK: - Ref helpers (mint through the shared registry the coordinator owns)

    /// The `workspace:N` ref JSON value for the configure result, minted through
    /// the same handle registry the coordinator uses so refs stay consistent.
    func controlWorkspaceRefValue(_ uuid: UUID) -> JSONValue {
        .string(controlCommandCoordinator.ensureRef(kind: .workspace, uuid: uuid))
    }

    /// The `window:N` ref JSON value (or `null` when absent) for the configure
    /// result.
    func controlWindowRefValue(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(controlCommandCoordinator.ensureRef(kind: .window, uuid: uuid))
    }

    /// The window id JSON value (or `null` when absent).
    func controlWindowOrNull(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(uuid.uuidString)
    }
}
