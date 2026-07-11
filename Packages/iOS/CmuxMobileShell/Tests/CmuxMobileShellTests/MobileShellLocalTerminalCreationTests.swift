import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func createTerminalFallsBackFromStalePaneWithoutDanglingMembership() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-live")],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["terminal-a"]
            ),
        ],
        focusedPaneID: "pane-live",
        selectedTerminalID: "terminal-a"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createLocalTerminal(in: workspace.id, paneID: "pane-stale")

    let updated = try #require(store.workspaces.first)
    let created = try #require(updated.terminals.last)
    #expect(created.paneID == "pane-live")
    #expect(updated.panes[0].terminalIDs.last == created.id)
}
