import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Test func profilingSelectionClassifiesTerminalInSelectedPane() {
    let snapshot = profilingSelectionSnapshot(selectedTerminalID: "terminal-a")

    #expect(snapshot.profilingSelectionKind(for: "terminal-b") == .terminalSwitch)
}

@Test func profilingSelectionClassifiesTerminalInAnotherPane() {
    let snapshot = profilingSelectionSnapshot(selectedTerminalID: "terminal-a")

    #expect(snapshot.profilingSelectionKind(for: "terminal-c") == .paneSwitch)
}

@Test func profilingSelectionFallsBackToFocusedPaneWhenSelectionIsMissing() {
    let snapshot = profilingSelectionSnapshot(selectedTerminalID: nil, focusedPaneID: "pane-left")

    #expect(snapshot.profilingSelectionKind(for: "terminal-c") == .paneSwitch)
}

@Test func profilingSelectionWithoutSelectedOrFocusedPaneDefaultsToTerminalSwitch() {
    let snapshot = profilingSelectionSnapshot(selectedTerminalID: nil, focusedPaneID: nil)

    #expect(snapshot.profilingSelectionKind(for: "terminal-c") == .terminalSwitch)
}

@Test func profilingSelectionIgnoresTheAlreadyActiveTerminal() {
    let snapshot = profilingSelectionSnapshot(selectedTerminalID: "terminal-a")

    #expect(snapshot.profilingSelectionKind(for: "terminal-a") == nil)
}

private func profilingSelectionSnapshot(
    selectedTerminalID: MobileTerminalPreview.ID?,
    focusedPaneID: MobilePanePreview.ID? = "pane-left"
) -> TerminalHierarchySnapshot {
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "Workspace",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-left"),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-left"),
            MobileTerminalPreview(id: "terminal-c", name: "C", paneID: "pane-right"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-left",
                spatialIndex: 0,
                isFocused: focusedPaneID == "pane-left",
                terminalIDs: ["terminal-a", "terminal-b"]
            ),
            MobilePanePreview(
                id: "pane-right",
                spatialIndex: 1,
                isFocused: focusedPaneID == "pane-right",
                terminalIDs: ["terminal-c"]
            ),
        ],
        focusedPaneID: focusedPaneID,
        selectedTerminalID: selectedTerminalID
    )
    return TerminalHierarchySnapshot(
        workspace: workspace,
        selectedTerminalID: selectedTerminalID
    )
}
