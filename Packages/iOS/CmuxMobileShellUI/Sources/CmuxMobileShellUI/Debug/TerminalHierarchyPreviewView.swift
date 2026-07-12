#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Deterministic two-pane hierarchy fixture for UI verification.
public struct TerminalHierarchyPreviewView: View {
    @State private var workspace: MobileWorkspacePreview
    @State private var selectedTerminalID: MobileTerminalPreview.ID?
    @State private var hasSimulatedMutationFailure = false
    @State private var reorderGate = MobileTerminalReorderGate()
    private let simulatesMutationFailure: Bool
    private let simulatesProtectedClose: Bool
    private let simulatesResultUnknownRefreshed: Bool

    /// Creates the preview fixture.
    public init() {
        let scenario = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_HIERARCHY_SCENARIO"]
            ?? ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("CMUX_UITEST_TERMINAL_HIERARCHY_SCENARIO=")
            })?.split(separator: "=", maxSplits: 1).last.map(String.init)
        var workspace = Self.initialWorkspace
        switch scenario {
        case "empty":
            workspace.terminals = []
            workspace.panes = []
            workspace.focusedPaneID = nil
            workspace.selectedTerminalID = nil
        case "single":
            workspace.terminals = Array(workspace.terminals.prefix(1))
            workspace.panes = [
                MobilePanePreview(
                    id: "pane-left",
                    spatialIndex: 0,
                    isFocused: true,
                    terminalIDs: workspace.terminals.map(\.id)
                ),
            ]
            workspace.focusedPaneID = "pane-left"
            workspace.selectedTerminalID = workspace.terminals.first?.id
        case "delayed":
            workspace.terminals[0].isReady = false
        case "disconnected":
            workspace.macConnectionStatus = .unavailable
        default:
            break
        }
        _workspace = State(initialValue: workspace)
        _selectedTerminalID = State(initialValue: workspace.selectedTerminalID)
        simulatesMutationFailure = scenario == "error"
        simulatesProtectedClose = scenario == "close-protected"
        simulatesResultUnknownRefreshed = scenario == "result-unknown-refreshed"
    }

    /// Renders the deterministic hierarchy fixture for UI verification.
    public var body: some View {
        TerminalHierarchySheet(
            snapshot: TerminalHierarchySnapshot(
                workspace: workspace,
                selectedTerminalID: selectedTerminalID
            ),
            createTerminal: createTerminal,
            selectTerminal: { selectedTerminalID = $0 },
            reorderGate: reorderGate,
            reorderTerminal: reorderTerminal,
            closeTerminal: closeTerminal,
            refreshTerminals: { true }
        )
    }

    private func createTerminal() {
        guard let paneID = workspace.terminalCreationPaneID,
              let paneIndex = workspace.panes.firstIndex(where: { $0.id == paneID }) else { return }
        let next = workspace.terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "terminal-created-\(next)"),
            name: "Agent",
            paneID: paneID
        )
        workspace.terminals.append(terminal)
        workspace.panes[paneIndex].terminalIDs.append(terminal.id)
        workspace.selectedTerminalID = terminal.id
        selectedTerminalID = terminal.id
    }

    private func reorderTerminal(
        _ intent: MobileTerminalReorderIntent,
        reservation: MobileTerminalReorderReservation
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        defer { reorderGate.finish(reservation) }
        if simulatesMutationFailure, !hasSimulatedMutationFailure {
            hasSimulatedMutationFailure = true
            return .failure(.notConnected(hostDisplayName: workspace.macDisplayName))
        }
        guard let paneIndex = workspace.panes.firstIndex(where: { $0.id == intent.paneID }),
              let sourceIndex = workspace.panes[paneIndex].terminalIDs.firstIndex(of: intent.terminalID) else {
            return .failure(.rejected(hostDisplayName: nil))
        }
        let terminalID = workspace.panes[paneIndex].terminalIDs.remove(at: sourceIndex)
        let destination = min(intent.targetIndex, workspace.panes[paneIndex].terminalIDs.count)
        workspace.panes[paneIndex].terminalIDs.insert(terminalID, at: destination)
        return .success(())
    }

    private func closeTerminal(
        _ terminalID: MobileTerminalPreview.ID,
        _ confirmed: Bool,
        reservation: MobileTerminalReorderReservation
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        defer { reorderGate.finish(reservation) }
        if simulatesMutationFailure, !hasSimulatedMutationFailure {
            hasSimulatedMutationFailure = true
            return .failure(.notConnected(hostDisplayName: workspace.macDisplayName))
        }
        if simulatesProtectedClose {
            return .failure(.protected(hostDisplayName: workspace.macDisplayName))
        }
        if simulatesResultUnknownRefreshed {
            return .failure(.resultUnknownRefreshed(hostDisplayName: workspace.macDisplayName))
        }
        guard let terminal = workspace.terminals.first(where: { $0.id == terminalID }),
              terminal.canClose else {
            return .failure(.rejected(hostDisplayName: nil))
        }
        if terminal.requiresCloseConfirmation, !confirmed {
            return .failure(.confirmationRequired(hostDisplayName: nil))
        }
        let paneID = terminal.paneID
        let fallbackIDs = paneID.map { workspace.terminals(in: $0).map(\.id) } ?? workspace.terminals.map(\.id)
        let fallback = MobileTerminalCloseFallback(
            closedTerminalID: terminalID,
            selectedTerminalID: selectedTerminalID,
            orderedTerminalIDs: fallbackIDs
        )
        workspace.terminals.removeAll { $0.id == terminalID }
        for index in workspace.panes.indices {
            workspace.panes[index].terminalIDs.removeAll { $0 == terminalID }
        }
        selectedTerminalID = fallback.resolvedSelection(
            availableTerminalIDs: Set(workspace.terminals.map(\.id))
        )
        workspace.selectedTerminalID = selectedTerminalID
        return .success(())
    }

    private static let initialWorkspace: MobileWorkspacePreview = {
        var workspace = MobileWorkspacePreview(
            id: "workspace-priority-8",
            macDisplayName: "Preview Mac",
            name: "Priority 8: a very long workspace name",
            terminals: [
                MobileTerminalPreview(id: "terminal-shell", name: "Shell", paneID: "pane-left"),
                MobileTerminalPreview(id: "terminal-agent-1", name: "Agent", paneID: "pane-left"),
                MobileTerminalPreview(
                    id: "terminal-agent-2",
                    name: "Agent",
                    paneID: "pane-right",
                    requiresCloseConfirmation: true,
                    isFocused: true
                ),
                MobileTerminalPreview(id: "terminal-long", name: "A terminal with an intentionally very long title", paneID: "pane-right"),
            ],
            panes: [
                MobilePanePreview(
                    id: "pane-left",
                    spatialIndex: 0,
                    terminalIDs: ["terminal-shell", "terminal-agent-1"]
                ),
                MobilePanePreview(
                    id: "pane-right",
                    spatialIndex: 1,
                    isFocused: true,
                    terminalIDs: ["terminal-agent-2", "terminal-long"]
                ),
            ],
            focusedPaneID: "pane-right",
            selectedTerminalID: "terminal-agent-2"
        )
        workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
            supportsTerminalCloseActions: true,
            supportsTerminalCreateInPane: true,
            supportsTerminalReorderActions: true
        )
        workspace.macConnectionStatus = .connected
        return workspace
    }()
}
#endif
