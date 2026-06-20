import CMUXMobileCore
internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

nonisolated private let terminalOverviewLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Returns the latest cached plain-text thumbnail rows for a terminal overview card.
    /// - Parameter terminalID: The terminal whose overview preview should be read.
    /// - Returns: Cached rows when a replay or live render-grid frame has populated them.
    public func terminalOverviewPreviewLines(for terminalID: MobileTerminalPreview.ID) -> [String]? {
        terminalOverviewPreviewLinesByID[terminalID]
    }

    /// Refreshes terminal overview thumbnails for every terminal in a workspace.
    ///
    /// The Mac remains the source of truth: each card asks for the same
    /// `mobile.terminal.replay` render-grid snapshot used by foreground terminal
    /// attach, then stores a bounded plain-text projection for SwiftUI.
    /// - Parameter workspaceID: The workspace whose terminal previews should refresh.
    public func refreshTerminalOverviewPreviews(in workspaceID: MobileWorkspacePreview.ID) async {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return
        }
        let liveTerminalIDs = Set(workspace.terminals.map(\.id))
        terminalOverviewPreviewLinesByID = terminalOverviewPreviewLinesByID.filter { liveTerminalIDs.contains($0.key) }
        let terminalsNeedingReplay = workspace.terminals.filter { terminal in
            terminal.isReady && terminalOverviewPreviewLinesByID[terminal.id] == nil
        }
        guard !terminalsNeedingReplay.isEmpty else {
            return
        }
        guard let client = remoteClient else {
            return
        }
        for terminal in terminalsNeedingReplay {
            guard !Task.isCancelled else { return }
            do {
                let lines = try await Self.requestTerminalOverviewPreviewLines(
                    workspaceID: workspaceID,
                    terminalID: terminal.id,
                    client: client
                )
                guard remoteClient === client, connectionState == .connected else { return }
                terminalOverviewPreviewLinesByID[terminal.id] = lines
            } catch {
                guard remoteClient === client, connectionState == .connected else { return }
                guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
                terminalOverviewLog.error("terminal overview preview failed workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminal.id.rawValue, privacy: .private) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes a terminal from the mobile tab overview.
    ///
    /// The Mac rejects protected cases such as closing the last terminal; iOS then
    /// re-syncs from the authoritative workspace list. Preview mode applies the
    /// same last-terminal rule against the in-memory fixtures.
    /// - Parameters:
    ///   - terminalID: The terminal to close.
    ///   - workspaceID: The workspace containing `terminalID`.
    public func closeTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) async {
        guard remoteClient != nil else {
            closePreviewTerminal(id: terminalID, in: workspaceID)
            return
        }
        guard supportsTerminalCloseActions else { return }
        await closeRemoteTerminal(id: terminalID, in: workspaceID)
    }

    nonisolated static func terminalOverviewPreviewLines(from renderGrid: MobileTerminalRenderGridFrame) -> [String] {
        guard renderGrid.full else { return [] }
        let rows = renderGrid.plainRows()
            .prefix(24)
            .map { terminalOverviewPreviewLine(from: $0) }
        guard rows.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return []
        }
        return rows
    }

    func pruneTerminalOverviewPreviewCacheForLiveTerminals() {
        let liveTerminalIDs = Set(workspaces.flatMap { $0.terminals.map(\.id) })
        terminalOverviewPreviewLinesByID = terminalOverviewPreviewLinesByID.filter { liveTerminalIDs.contains($0.key) }
    }

    // Keep RPC send/decode work off MobileShellComposite's main-actor state owner.
    nonisolated private static func requestTerminalOverviewPreviewLines(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        client: MobileCoreRPCClient
    ) async throws -> [String] {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.replay",
            params: [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
            ]
        )
        let data = try await client.sendRequest(request)
        let payload = try MobileTerminalReplayResponse.decode(data)
        guard let renderGrid = payload.renderGrid,
              renderGrid.surfaceID == terminalID.rawValue else {
            return []
        }
        return terminalOverviewPreviewLines(from: renderGrid)
    }

    private func closeRemoteTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) async {
        guard let client = remoteClient else { return }
        do {
            let response = try await Self.requestCloseRemoteTerminal(
                workspaceID: workspaceID,
                terminalID: terminalID,
                clientID: clientID,
                client: client
            )
            guard remoteClient === client,
                  connectionState == .connected,
                  !Task.isCancelled else { return }
            terminalOverviewPreviewLinesByID[terminalID] = nil
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
        } catch {
            guard remoteClient === client, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            terminalOverviewLog.error("terminal close failed workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private) error=\(String(describing: error), privacy: .public)")
            await refreshWorkspaces()
        }
    }

    // Keep RPC send/decode work off MobileShellComposite's main-actor state owner.
    nonisolated private static func requestCloseRemoteTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        clientID: String,
        client: MobileCoreRPCClient
    ) async throws -> MobileSyncWorkspaceListResponse {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.close",
            params: [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "client_id": clientID,
            ]
        )
        let responseData = try await client.sendRequest(request)
        return try MobileSyncWorkspaceListResponse.decode(responseData)
    }

    private func closePreviewTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return
        }
        let terminals = workspaces[workspaceIndex].terminals
        guard terminals.count > 1,
              let closingIndex = terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        workspaces[workspaceIndex].terminals.remove(at: closingIndex)
        terminalOverviewPreviewLinesByID[terminalID] = nil
        if selectedWorkspaceID == workspaceID, selectedTerminalID == terminalID {
            let remaining = workspaces[workspaceIndex].terminals
            let replacementIndex = min(closingIndex, remaining.count - 1)
            selectedTerminalID = remaining.indices.contains(replacementIndex)
                ? remaining[replacementIndex].id
                : remaining.first?.id
        }
    }

    nonisolated private static func terminalOverviewPreviewLine(from row: String) -> String {
        let trimmedRight = row.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()
        let line = String(trimmedRight)
        guard line.count > 160 else {
            return line
        }
        let cutoff = line.index(line.startIndex, offsetBy: 160)
        return String(line[..<cutoff])
    }
}
