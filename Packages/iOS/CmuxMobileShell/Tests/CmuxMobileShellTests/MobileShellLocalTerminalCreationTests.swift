import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func remoteCreateDoesNotSendPresentationOnlyLegacyPaneID() {
    let store = MobileShellComposite.preview()
    var workspace = MobileWorkspacePreview(
        id: "workspace-legacy",
        name: "Legacy project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell")]
    )
    workspace.actionCapabilities.supportsTerminalCreateInPane = true

    #expect(workspace.terminalCreationPaneID == "workspace-legacy-legacy-pane")
    #expect(store.remoteTerminalCreationPaneID(
        in: workspace,
        explicitPaneID: nil
    ) == nil)
}

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

@MainActor
@Test func remoteCreateFallsBackFromStaleFocusedAndExplicitPaneIDs() {
    let store = MobileShellComposite.preview()
    var workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-live")],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: false,
                terminalIDs: ["terminal-a"]
            ),
        ],
        focusedPaneID: "pane-stale",
        selectedTerminalID: "terminal-a"
    )
    workspace.actionCapabilities.supportsTerminalCreateInPane = true

    #expect(store.remoteTerminalCreationPaneID(
        in: workspace,
        explicitPaneID: "pane-also-stale"
    ) == "pane-live")
}

@MainActor
@Test func createTerminalDoesNotDuplicateAnExistingIDAfterDeletion() throws {
    let store = MobileShellComposite.preview()
    let workspace = MobileWorkspacePreview(
        id: "workspace-pane",
        name: "Pane project",
        terminals: [
            MobileTerminalPreview(id: "workspace-pane-terminal-2", name: "shell", paneID: "pane-live"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-live",
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: ["workspace-pane-terminal-2"]
            ),
        ],
        focusedPaneID: "pane-live",
        selectedTerminalID: "workspace-pane-terminal-2"
    )
    store.replaceForegroundWorkspaceState([workspace])

    store.createLocalTerminal(in: workspace.id, paneID: "pane-live")

    let updated = try #require(store.workspaces.first)
    #expect(Set(updated.terminals.map(\.id)).count == updated.terminals.count)
    #expect(updated.terminals.last?.id == "workspace-pane-terminal-3")
}

@MainActor
@Test func createTerminalWithoutPaneCapabilityUsesFocusedLocalPane() throws {
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

    store.createTerminal(in: workspace.id)

    let updated = try #require(store.workspaces.first)
    let created = try #require(updated.terminals.last)
    #expect(created.paneID == "pane-live")
    #expect(updated.panes[0].terminalIDs.last == created.id)
}
