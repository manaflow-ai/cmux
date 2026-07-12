import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Test func hierarchySnapshotGroupsByPaneAndDisambiguatesDuplicateTitles() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "A very long workspace name used for Dynamic Type coverage",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-left"),
            MobileTerminalPreview(
                id: "terminal-b",
                name: "shell",
                paneID: "pane-left",
                requiresCloseConfirmation: true
            ),
            MobileTerminalPreview(id: "terminal-c", name: "logs", paneID: "pane-right"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-left",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-a", "terminal-b"]
            ),
            MobilePanePreview(
                id: "pane-right",
                spatialIndex: 1,
                terminalIDs: ["terminal-c"]
            ),
        ],
        focusedPaneID: "pane-left",
        selectedTerminalID: "terminal-b"
    )

    let snapshot = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: "terminal-b")
    #expect(snapshot.panes.map(\.id) == ["pane-left", "pane-right"])
    #expect(snapshot.panes[0].rows.map(\.duplicateOrdinal) == [1, 2])
    #expect(snapshot.panes[0].rows.map(\.isSelected) == [false, true])
    #expect(snapshot.panes[1].rows.first?.duplicateOrdinal == nil)
    let activeRow = try #require(snapshot.panes[0].rows.last)
    let accessibilityLabel = activeRow.accessibilityLabel.lowercased()
    #expect(accessibilityLabel.contains("terminal"))
    #expect(accessibilityLabel.contains("workspace a very long workspace name"))
    #expect(accessibilityLabel.contains("pane 1"))
    #expect(accessibilityLabel.contains("active"))
    #expect(!accessibilityLabel.contains("surface"))
    #expect(!accessibilityLabel.contains("tab"))
    let closeLabel = activeRow.closeAccessibilityLabel.lowercased()
    #expect(closeLabel.contains("shell, 2"))
    #expect(closeLabel.contains("workspace a very long workspace name"))
    #expect(closeLabel.contains("pane 1"))
    let consequence = activeRow.closeConsequence.lowercased()
    #expect(consequence.contains("shell, 2"))
    #expect(consequence.contains("workspace a very long workspace name"))
    #expect(consequence.contains("pane 1"))
    #expect(consequence.contains("running process"))
    #expect(!consequence.contains("surface"))
    #expect(!consequence.contains("tab"))
    let ordinaryRow = try #require(snapshot.panes[0].rows.first)
    #expect(!ordinaryRow.closeConsequence.lowercased().contains("running process"))
    #expect(ordinaryRow.closeConsequence(requiresProcessConfirmation: true)
        .lowercased().contains("running process"))
}

@Test func hierarchyOptimisticOrderAppliesAndCanRollbackToPreviousIdentityOrder() throws {
    let pane = MobilePanePreview(
        id: "pane-left",
        spatialIndex: 0,
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"]
    )
    let intent = try #require(MobileTerminalReorderIntent(
        terminalID: "terminal-a",
        sourceIndex: 0,
        destinationIndex: 3,
        pane: pane
    ))
    let previous = pane.terminalIDs
    #expect(intent.applying(to: previous) == [
        "terminal-b", "terminal-c", "terminal-a",
    ])
    #expect(previous == ["terminal-a", "terminal-b", "terminal-c"])
}

@Test func hierarchySnapshotHandlesEmptyAndSingleTerminalWorkspaces() {
    let empty = MobileWorkspacePreview(id: "empty", name: "Empty", terminals: [])
    #expect(TerminalHierarchySnapshot(workspace: empty, selectedTerminalID: nil).panes.isEmpty)

    let terminal = MobileTerminalPreview(id: "only", name: "Only")
    let single = MobileWorkspacePreview(id: "single", name: "Single", terminals: [terminal])
    let snapshot = TerminalHierarchySnapshot(workspace: single, selectedTerminalID: terminal.id)
    #expect(snapshot.panes.count == 1)
    #expect(snapshot.panes[0].rows.first?.isSelected == true)
    #expect(snapshot.connectionStatus == .unavailable)
}

@Test func hierarchySnapshotDeduplicatesMalformedPaneMembership() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace-duplicate-membership",
        name: "Duplicate membership",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "Shell")],
        panes: [
            MobilePanePreview(
                id: "pane-a",
                spatialIndex: 0,
                terminalIDs: ["terminal-a", "terminal-a"]
            ),
        ]
    )

    let pane = try #require(
        TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil).panes.first
    )
    #expect(pane.rows.map(\.id) == ["terminal-a"])
}
