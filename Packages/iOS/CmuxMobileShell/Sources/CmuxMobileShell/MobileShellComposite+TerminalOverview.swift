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
        guard let client = remoteClient else {
            return
        }
        for terminal in workspace.terminals {
            guard !Task.isCancelled else { return }
            do {
                let lines = try await requestTerminalOverviewPreviewLines(
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

    static func terminalOverviewPreviewLines(from renderGrid: MobileTerminalRenderGridFrame) -> [String] {
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

    private func requestTerminalOverviewPreviewLines(
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
        return Self.terminalOverviewPreviewLines(from: renderGrid)
    }

    private func closeRemoteTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.close",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": terminalID.rawValue,
                    "client_id": clientID,
                ]
            )
            let responseData = try await client.sendRequest(request)
            let response = try MobileSyncWorkspaceListResponse.decode(responseData)
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

    private static func terminalOverviewPreviewLine(from row: String) -> String {
        let trimmedRight = row.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()
        let line = String(trimmedRight)
        guard line.count > 160 else {
            return line
        }
        let cutoff = line.index(line.startIndex, offsetBy: 160)
        return String(line[..<cutoff])
    }
}

#if DEBUG
extension MobileShellComposite {
    /// Builds a connected preview store for terminal overview simulator screenshots.
    ///
    /// This is only used by the DEBUG `CMUX_UITEST_TERMINAL_OVERVIEW_PREVIEW`
    /// launch hook. It avoids real auth/pairing dependencies while exercising
    /// the same workspace, toolbar, and overview grid views as the app.
    public static func terminalOverviewPreviewHarnessStore() -> CMUXMobileShellStore {
        let store = preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        store.terminalOverviewPreviewLinesByID = [
            "terminal-build": [
                "$ CMUX_SKIP_ZIG_BUILD=1 ./ios/scripts/reload.sh --tag issue-6347-ios-tab-overview",
                "Building cmux-ios for iPhone 17 simulator",
                "Compile Swift sources",
                "Install and launch dev.cmux.ios.issue-6347-ios-tab-overview",
                "Build succeeded",
            ],
            "terminal-agent": [
                "$ swift test --package-path Packages/iOS/CmuxMobileShell --filter MobileShellCompositePreviewTests",
                "Suite MobileShellCompositePreviewTests started",
                "overviewPreviewLinesUseRenderGridRows passed",
                "closeTerminalRemovesSelectedTerminalAndSelectsNeighbor passed",
                "Test run with 16 tests passed",
            ],
            "terminal-tui": [
                "LAZYGIT",
                "files branches log",
                "main issue-6347-ios-tab-overview",
                "A TerminalTabOverviewView.swift",
                "A TerminalTabOverviewCard.swift",
            ],
            "terminal-notes": [
                "$ rg terminal overview docs",
                "iOS Safari-style tab switcher",
                "grid previews, close buttons, and tab count",
            ],
        ]
        return store
    }
}
#endif
