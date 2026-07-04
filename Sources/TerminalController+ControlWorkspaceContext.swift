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
            currentDirectory: workspace.currentDirectory,
            defaultWorkingDirectory: workspace.defaultWorkingDirectory,
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

    // MARK: - Default cwd

    func controlGetWorkspaceDefaultDirectory(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceDefaultDirectoryResolution {
        let tabManager: TabManager
        let workspace: Workspace
        if let workspaceID {
            guard let resolvedTabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let resolvedWorkspace = resolvedTabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .notFound
            }
            tabManager = resolvedTabManager
            workspace = resolvedWorkspace
        } else {
            guard let resolvedTabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let selectedWorkspace = resolvedTabManager.selectedWorkspace else {
                return .noWorkspaceSelected
            }
            tabManager = resolvedTabManager
            workspace = selectedWorkspace
        }
        return .resolved(
            windowID: AppDelegate.shared?.windowId(for: tabManager),
            workspaceID: workspace.id,
            cwd: workspace.defaultWorkingDirectory
        )
    }

    func controlSetWorkspaceDefaultDirectory(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        cwd: String
    ) -> ControlWorkspaceDefaultDirectoryResolution {
        let tabManager: TabManager
        let workspace: Workspace
        if let workspaceID {
            guard let resolvedTabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let resolvedWorkspace = resolvedTabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .notFound
            }
            tabManager = resolvedTabManager
            workspace = resolvedWorkspace
        } else {
            guard let resolvedTabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let selectedWorkspace = resolvedTabManager.selectedWorkspace else {
                return .noWorkspaceSelected
            }
            tabManager = resolvedTabManager
            workspace = selectedWorkspace
        }
        workspace.setDefaultWorkingDirectory(cwd, syncCurrentDirectory: false)
        return .resolved(
            windowID: AppDelegate.shared?.windowId(for: tabManager),
            workspaceID: workspace.id,
            cwd: workspace.defaultWorkingDirectory
        )
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

    func controlConfigureWorkspaceRemote(
        params typedParams: [String: JSONValue],
        workspaceID workspaceId: UUID
    ) -> ControlCallResult {
        // The configure body validates ~40 params against the app's
        // `WorkspaceRemote*` types, so it stays app-side. Bridge the typed params
        // back to the `[String: Any]` shape the legacy `v2*` param helpers expect
        // so the acceptance is byte-identical.
        let params: [String: Any] = typedParams.mapValues(\.foundationObject)

        guard let destination = v2String(params, "destination") else {
            return .err(code: "invalid_params", message: "Missing destination", data: nil)
        }

        var sshPort: Int?
        if v2HasNonNullParam(params, "port") {
            guard let parsedPort = v2StrictInt(params, "port"),
                  parsedPort > 0,
                  parsedPort <= 65535 else {
                return .err(code: "invalid_params", message: "port must be 1-65535", data: nil)
            }
            sshPort = parsedPort
        }

        var localProxyPort: Int?
        if v2HasNonNullParam(params, "local_proxy_port") {
            guard let parsedLocalProxyPort = v2StrictInt(params, "local_proxy_port"),
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .err(code: "invalid_params", message: "local_proxy_port must be 1-65535", data: nil)
            }
            localProxyPort = parsedLocalProxyPort
        }

        let identityFile = v2RawString(params, "identity_file")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshOptions = v2StringArray(params, "ssh_options") ?? []
        let transportRaw = v2RawString(params, "transport")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let transport = WorkspaceRemoteTransport(rawValue: transportRaw ?? "") ?? .ssh
        let autoConnect = v2Bool(params, "auto_connect") ?? true
        var relayPort: Int?
        if v2HasNonNullParam(params, "relay_port") {
            guard let parsedRelayPort = v2StrictInt(params, "relay_port"),
                  parsedRelayPort > 0,
                  parsedRelayPort <= 65535 else {
                return .err(code: "invalid_params", message: "relay_port must be 1-65535", data: nil)
            }
            relayPort = parsedRelayPort
        }
        let relayID = v2RawString(params, "relay_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayToken = v2RawString(params, "relay_token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let foregroundAuthToken = v2RawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localSocketPath = v2RawString(params, "local_socket_path")
        let hasExplicitAgentSocketPath = v2HasNonNullParam(params, "ssh_auth_sock")
        let agentSocketPath = v2RawString(params, "ssh_auth_sock")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalStartupCommand = v2RawString(params, "terminal_startup_command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var persistentDaemonSlot = v2RawString(params, "persistent_daemon_slot")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if v2HasNonNullParam(params, "persistent_daemon_slot") {
            guard let persistentDaemonSlot,
                  !persistentDaemonSlot.isEmpty,
                  persistentDaemonSlot.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  persistentDaemonSlot != ".",
                  persistentDaemonSlot != ".." else {
                return .err(
                    code: "invalid_params",
                    message: "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'",
                    data: nil
                )
            }
        }
        let daemonWebSocketURL = v2RawString(params, "daemon_websocket_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketToken = v2RawString(params, "daemon_websocket_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketSessionID = v2RawString(params, "daemon_websocket_session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketExpiresAtUnix = (params["daemon_websocket_expires_at_unix"] as? Int64)
            ?? Int64((params["daemon_websocket_expires_at_unix"] as? Double) ?? 0)
        let rawDaemonHeaders = params["daemon_websocket_headers"] as? [String: Any] ?? [:]
        let daemonWebSocketHeaders = rawDaemonHeaders.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            }
        }
        let daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint?
        if let daemonWebSocketURL,
           !daemonWebSocketURL.isEmpty,
           let daemonWebSocketToken,
           !daemonWebSocketToken.isEmpty,
           let daemonWebSocketSessionID,
           !daemonWebSocketSessionID.isEmpty {
            daemonWebSocketEndpoint = WorkspaceRemoteWebSocketDaemonEndpoint(
                url: daemonWebSocketURL,
                headers: daemonWebSocketHeaders,
                token: daemonWebSocketToken,
                sessionId: daemonWebSocketSessionID,
                expiresAtUnix: daemonWebSocketExpiresAtUnix
            )
        } else {
            daemonWebSocketEndpoint = nil
        }
        let preserveAfterTerminalExit = v2Bool(params, "preserve_after_terminal_exit") ?? false
        if v2HasNonNullParam(params, "preserve_after_terminal_exit"),
           v2Bool(params, "preserve_after_terminal_exit") == nil {
            return .err(
                code: "invalid_params",
                message: "preserve_after_terminal_exit must be a boolean",
                data: nil
            )
        }
        let skipDaemonBootstrap = v2Bool(params, "skip_daemon_bootstrap") ?? false
        if persistentDaemonSlot != nil, !preserveAfterTerminalExit {
            return .err(
                code: "invalid_params",
                message: "preserve_after_terminal_exit is required when persistent_daemon_slot is set",
                data: nil
            )
        }
        if preserveAfterTerminalExit,
           transport == .ssh,
           !skipDaemonBootstrap,
           daemonWebSocketEndpoint == nil,
           persistentDaemonSlot == nil {
            persistentDaemonSlot = "ssh-\(workspaceId.uuidString.lowercased())"
        }
        if relayPort != nil {
            guard let relayID, !relayID.isEmpty else {
                return .err(code: "invalid_params", message: "relay_id is required when relay_port is set", data: nil)
            }
            guard let relayToken,
                  relayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return .err(code: "invalid_params", message: "relay_token must be 64 lowercase hex characters when relay_port is set", data: nil)
            }
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.remote.configure.request workspace=\(workspaceId.uuidString.prefix(8)) " +
            "target=\(destination) transport=\(transport.rawValue) port=\(sshPort.map(String.init) ?? "nil") " +
            "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(localSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? localSocketPath! : "nil") " +
            "sshAuthSock=\(agentSocketPath?.isEmpty == false ? 1 : 0) " +
            "sshOptions=\(sshOptions.joined(separator: "|"))"
        )
#endif

        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceId.uuidString),
                "workspace_ref": controlWorkspaceRefValue(workspaceId),
            ]))
        }

        let config = WorkspaceRemoteConfiguration(
            transport: transport,
            destination: destination,
            port: sshPort,
            identityFile: identityFile?.isEmpty == true ? nil : identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID?.isEmpty == true ? nil : relayID,
            relayToken: relayToken?.isEmpty == true ? nil : relayToken,
            localSocketPath: localSocketPath,
            terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand,
            foregroundAuthToken: foregroundAuthToken?.isEmpty == true ? nil : foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: sshOptions,
                explicitAgentSocketPath: agentSocketPath,
                explicitAgentSocketPathIsSet: hasExplicitAgentSocketPath
            ),
            daemonWebSocketEndpoint: daemonWebSocketEndpoint,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot?.isEmpty == true ? nil : persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
        workspace.configureRemoteConnection(config, autoConnect: autoConnect)
        notifyRemotePTYControllerAvailabilityChanged()

        let windowId = AppDelegate.shared?.windowId(for: owner)
        return .ok(.object([
            "window_id": controlWindowOrNull(windowId),
            "window_ref": controlWindowRefValue(windowId),
            "workspace_id": .string(workspace.id.uuidString),
            "workspace_ref": controlWorkspaceRefValue(workspace.id),
            "remote": JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:]),
        ]))
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
    private func controlWorkspaceRefValue(_ uuid: UUID) -> JSONValue {
        .string(controlCommandCoordinator.ensureRef(kind: .workspace, uuid: uuid))
    }

    /// The `window:N` ref JSON value (or `null` when absent) for the configure
    /// result.
    private func controlWindowRefValue(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(controlCommandCoordinator.ensureRef(kind: .window, uuid: uuid))
    }

    /// The window id JSON value (or `null` when absent).
    private func controlWindowOrNull(_ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(uuid.uuidString)
    }
}
