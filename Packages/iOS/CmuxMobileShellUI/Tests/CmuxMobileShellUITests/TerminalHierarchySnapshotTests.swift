import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Test func hierarchySnapshotGroupsByPaneAndDisambiguatesDuplicateTitles() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "A very long workspace name used for Dynamic Type coverage",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-left"),
            MobileTerminalPreview(id: "terminal-b", name: "shell", paneID: "pane-left"),
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
}

@Test func hierarchySnapshotHandlesEmptyAndSingleTerminalWorkspaces() {
    let empty = MobileWorkspacePreview(id: "empty", name: "Empty", terminals: [])
    #expect(TerminalHierarchySnapshot(workspace: empty, selectedTerminalID: nil).panes.isEmpty)

    let terminal = MobileTerminalPreview(id: "only", name: "Only")
    let single = MobileWorkspacePreview(id: "single", name: "Single", terminals: [terminal])
    let snapshot = TerminalHierarchySnapshot(workspace: single, selectedTerminalID: terminal.id)
    #expect(snapshot.panes.count == 1)
    #expect(snapshot.panes[0].rows.first?.isSelected == true)
}
