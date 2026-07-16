import CmuxAgentChat
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite: PaneTailReplayRequesting {
    static var workspacePanesCapability: String { "workspace.panes.v1" }
    static var terminalCloseCapability: String { "terminal.close.v1" }

    /// Returns immutable Pane Rack state for one workspace.
    /// - Parameter workspaceID: Workspace row identifier.
    /// - Returns: A rack snapshot, or `nil` when the workspace has no terminal panes.
    public func paneRackSnapshot(for workspaceID: MobileWorkspacePreview.ID) -> PaneRackSnapshot? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        let supportsNativePanes = paneRackCapabilities(for: workspace).contains(Self.workspacePanesCapability)
        var navigation = paneRackNavigationState
        _ = navigation.reconcile(workspace: workspace, supportsNativePanes: supportsNativePanes)
        let panes = navigation.projectedPanes(
            workspace: workspace,
            supportsNativePanes: supportsNativePanes
        )
        guard let stagedPaneID = navigation.stagedPaneID(workspaceID: workspace.id), !panes.isEmpty else {
            return nil
        }
        let terminalsByID = Dictionary(uniqueKeysWithValues: workspace.terminals.map { ($0.id.rawValue, $0) })
        let paneSnapshots = panes.map { pane in
            PaneRackPaneSnapshot(
                id: pane.id,
                rect: pane.rect,
                isMacFocused: pane.isFocused,
                selectedTabID: navigation.effectiveSelectedTabID(workspaceID: workspace.id, paneID: pane.id)
                    .map(MobileTerminalPreview.ID.init(rawValue:)),
                tabs: pane.tabIDs.compactMap { surfaceID in
                    guard let terminal = terminalsByID[surfaceID] else { return nil }
                    return PaneRackTabSnapshot(
                        id: terminal.id,
                        title: terminal.name,
                        isReady: terminal.isReady,
                        isMacFocused: terminal.isFocused,
                        agentState: agentState(forTerminalID: surfaceID)
                    )
                }
            )
        }
        return PaneRackSnapshot(
            workspaceID: workspace.id,
            panes: paneSnapshots,
            stagedPaneID: stagedPaneID,
            canCloseTabs: paneRackCapabilities(for: workspace).contains(Self.terminalCloseCapability)
        )
    }

    /// Stages one pane on the phone without changing Mac focus.
    /// - Parameters:
    ///   - paneID: Pane identifier to stage.
    ///   - workspaceID: Workspace containing the pane.
    public func stagePane(_ paneID: String, in workspaceID: MobileWorkspacePreview.ID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let terminalID = paneRackNavigationState.stagePane(
            paneID,
            workspace: workspace,
            supportsNativePanes: paneRackSupportsNativePanes(for: workspace)
        )
        selectedWorkspaceID = workspaceID
        selectPaneRackTerminal(terminalID)
    }

    /// Selects one terminal tab on the phone and stages its pane.
    /// - Parameters:
    ///   - surfaceID: Terminal surface identifier.
    ///   - paneID: Pane containing the terminal.
    ///   - workspaceID: Workspace containing the pane.
    public func selectTab(
        _ surfaceID: String,
        inPane paneID: String,
        workspaceID: MobileWorkspacePreview.ID
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let terminalID = paneRackNavigationState.selectTab(
            surfaceID,
            inPane: paneID,
            workspace: workspace,
            supportsNativePanes: paneRackSupportsNativePanes(for: workspace)
        )
        selectedWorkspaceID = workspaceID
        selectPaneRackTerminal(terminalID)
    }

    /// Closes one terminal tab with optimistic removal and rollback on failure.
    /// - Parameters:
    ///   - surfaceID: Terminal surface identifier to close.
    ///   - workspaceID: Workspace containing the terminal.
    /// - Returns: Success or a structured failure for the rack UI.
    @discardableResult
    public func closeTab(
        _ surfaceID: String,
        workspaceID: MobileWorkspacePreview.ID
    ) async -> Result<Void, PaneRackMutationFailure> {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.terminals.contains(where: { $0.id.rawValue == surfaceID }) else {
            return .failure(.invalidTarget)
        }
        guard paneRackCapabilities(for: workspace).contains(Self.terminalCloseCapability) else {
            return .failure(.unsupported)
        }
        let target = workspaceMutationTarget(for: workspaceID)
        guard target.client != nil || paneRackRequestSender != nil else {
            return .failure(.notConnected)
        }
        guard let ownerKey = paneRackOwnerKey(for: workspace),
              let previousMacState = workspacesByMac[ownerKey] else {
            return .failure(.invalidTarget)
        }
        let previousNavigation = paneRackNavigationState
        optimisticallyRemoveTab(surfaceID, workspace: workspace, ownerKey: ownerKey)

        let request = PaneRackRequest(
            method: "mobile.terminal.close",
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            surfaceID: surfaceID,
            clientID: clientID,
            windowID: workspace.windowID
        )
        do {
            let responseData = try await sendPaneRackRequest(request, target: target)
            if target.isForeground,
               let response = try? MobileSyncWorkspaceListResponse.decode(responseData) {
                applyRemoteWorkspaceList(response)
            } else {
                await refreshAfterWorkspaceMutation(target)
            }
            return .success(())
        } catch {
            paneRackNavigationState = previousNavigation
            workspacesByMac[ownerKey] = previousMacState
            mobileShellLog.error("pane rack close failed workspace=\(workspaceID.rawValue, privacy: .public) surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            applyOperationalError(error)
            if case let MobileShellConnectionError.rpcError(code, message) = error,
               code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "last_terminal" {
                return .failure(.lastTerminal(message: message))
            }
            return .failure(.rejected(message: (error as? any LocalizedError)?.errorDescription ?? String(describing: error)))
        }
    }

    /// Creates and selects a terminal tab in one pane.
    /// - Parameters:
    ///   - paneID: Target pane identifier. Ignored for old-Mac implicit panes.
    ///   - workspaceID: Workspace containing the pane.
    /// - Returns: Success or a structured failure for the rack UI.
    @discardableResult
    public func createTab(
        inPane paneID: String,
        workspaceID: MobileWorkspacePreview.ID
    ) async -> Result<Void, PaneRackMutationFailure> {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return .failure(.invalidTarget)
        }
        let target = workspaceMutationTarget(for: workspaceID)
        guard target.client != nil || paneRackRequestSender != nil else {
            return .failure(.notConnected)
        }
        let supportsNativePanes = paneRackSupportsNativePanes(for: workspace)
        let nativePaneID: String?
        if supportsNativePanes {
            guard workspace.panes.contains(where: { $0.id == paneID }) else {
                return .failure(.invalidTarget)
            }
            nativePaneID = paneID
        } else {
            nativePaneID = nil
        }
        let request = PaneRackRequest(
            method: "terminal.create",
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            paneID: nativePaneID,
            clientID: clientID,
            windowID: workspace.windowID
        )
        do {
            let responseData = try await sendPaneRackRequest(request, target: target)
            let response = try MobileSyncWorkspaceListResponse.decode(responseData)
            if target.isForeground {
                applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            } else {
                await refreshAfterWorkspaceMutation(target)
            }
            guard let createdSurfaceID = response.createdTerminalID,
                  let refreshedWorkspace = workspaces.first(where: { $0.id == workspaceID }) else {
                return .success(())
            }
            let refreshedPaneID = nativePaneID
                ?? paneRackNavigationState.implicitPaneID(workspaceID: refreshedWorkspace.id)
            let terminalID = paneRackNavigationState.selectTab(
                createdSurfaceID,
                inPane: refreshedPaneID,
                workspace: refreshedWorkspace,
                supportsNativePanes: supportsNativePanes
            )
            selectPaneRackTerminal(terminalID)
            suppressTerminalAutoFocusOnNextAttach(for: terminalID)
            return .success(())
        } catch {
            mobileShellLog.error("pane rack create failed workspace=\(workspaceID.rawValue, privacy: .public) pane=\(paneID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            applyOperationalError(error)
            return .failure(.rejected(message: (error as? any LocalizedError)?.errorDescription ?? String(describing: error)))
        }
    }

    /// Returns the joined agent state for one terminal surface.
    /// - Parameter terminalID: Terminal surface identifier.
    /// - Returns: The highest-priority cached session state, or `.idle` when none exists.
    public func agentState(forTerminalID terminalID: String) -> PaneRackAgentState {
        guard let workspace = workspaces.first(where: {
            $0.terminals.contains(where: { $0.id.rawValue == terminalID })
        }) else { return .idle }
        let sessions = cachedChatSessions(workspaceID: workspace.id.rawValue)
            + (workspace.rpcWorkspaceID == workspace.id
                ? []
                : cachedChatSessions(workspaceID: workspace.rpcWorkspaceID.rawValue))
        guard let state = ChatSessionDescriptor.openable(
            sessions.filter { $0.terminalID == terminalID }
        ).first?.state else { return .idle }
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .needsInput: return .needsInput
        case .ended: return .ended
        }
    }

    func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        selectedTerminalID = paneRackNavigationState.reconcile(
            workspace: selectedWorkspace,
            supportsNativePanes: paneRackSupportsNativePanes(for: selectedWorkspace)
        )
    }

    func selectTerminalInPaneRack(_ id: MobileTerminalPreview.ID?) {
        guard let id,
              let workspace = selectedWorkspace else {
            selectedTerminalID = id
            return
        }
        let panes = paneRackNavigationState.projectedPanes(
            workspace: workspace,
            supportsNativePanes: paneRackSupportsNativePanes(for: workspace)
        )
        guard let pane = panes.first(where: { $0.tabIDs.contains(id.rawValue) }) else {
            selectedTerminalID = id
            return
        }
        selectedTerminalID = paneRackNavigationState.selectTab(
            id.rawValue,
            inPane: pane.id,
            workspace: workspace,
            supportsNativePanes: paneRackSupportsNativePanes(for: workspace)
        )
    }

    func requestPaneTailReplay(surfaceID: String) {
        requestTerminalReplay(surfaceID: surfaceID)
    }

    func paneRackSupportsNativePanes(for workspace: MobileWorkspacePreview) -> Bool {
        paneRackCapabilities(for: workspace).contains(Self.workspacePanesCapability)
    }

    private func paneRackCapabilities(for workspace: MobileWorkspacePreview) -> Set<String> {
        guard let macDeviceID = workspace.macDeviceID,
              macDeviceID != foregroundMacDeviceID,
              macDeviceID != Self.foregroundAnonymousKey else {
            return supportedHostCapabilities
        }
        return secondaryMacSubscriptions[macDeviceID]?.supportedHostCapabilities ?? []
    }

    private func selectPaneRackTerminal(_ terminalID: MobileTerminalPreview.ID?) {
        if let terminalID, terminalID != selectedTerminalID {
            suppressTerminalAutoFocusOnNextAttach(for: terminalID)
        }
        selectedTerminalID = terminalID
    }

    private func paneRackOwnerKey(for workspace: MobileWorkspacePreview) -> String? {
        if let macDeviceID = workspace.macDeviceID, workspacesByMac[macDeviceID] != nil {
            return macDeviceID
        }
        if workspacesByMac[foregroundMacKey] != nil {
            return foregroundMacKey
        }
        return workspacesByMac.first(where: { _, state in
            state.workspaces.contains(where: { $0.rpcWorkspaceID == workspace.rpcWorkspaceID })
        })?.key
    }

    private func optimisticallyRemoveTab(
        _ surfaceID: String,
        workspace: MobileWorkspacePreview,
        ownerKey: String
    ) {
        guard var state = workspacesByMac[ownerKey],
              let index = state.workspaces.firstIndex(where: {
                  $0.rpcWorkspaceID == workspace.rpcWorkspaceID
              }) else { return }
        state.workspaces[index].terminals.removeAll { $0.id.rawValue == surfaceID }
        state.workspaces[index].panes = state.workspaces[index].panes.compactMap { pane in
            var pane = pane
            pane.tabIDs.removeAll { $0 == surfaceID }
            guard !pane.tabIDs.isEmpty else { return nil }
            if pane.selectedTabID == surfaceID {
                pane.selectedTabID = pane.tabIDs.first
            }
            return pane
        }
        workspacesByMac[ownerKey] = state
    }

    private func sendPaneRackRequest(
        _ request: PaneRackRequest,
        target: WorkspaceMutationTarget
    ) async throws -> Data {
        if let paneRackRequestSender {
            return try await paneRackRequestSender.sendPaneRackRequest(request)
        }
        guard let client = target.client else {
            throw MobileShellConnectionError.connectionClosed
        }
        var params: [String: Any] = [
            "workspace_id": request.workspaceID,
            "client_id": request.clientID,
        ]
        if let surfaceID = request.surfaceID { params["surface_id"] = surfaceID }
        if let paneID = request.paneID { params["pane_id"] = paneID }
        if let windowID = request.windowID { params["window_id"] = windowID }
        return try await client.sendRequest(
            MobileCoreRPCClient.requestData(method: request.method, params: params)
        )
    }
}
