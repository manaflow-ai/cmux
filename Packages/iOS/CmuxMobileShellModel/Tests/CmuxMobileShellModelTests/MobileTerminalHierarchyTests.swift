import Testing
@testable import CmuxMobileShellModel

@Test func paneHierarchyPreservesStableSpatialAndTerminalOrder() {
    let first = MobileTerminalPreview(id: "terminal-a", name: "shell", paneID: "pane-left")
    let second = MobileTerminalPreview(id: "terminal-b", name: "shell", paneID: "pane-right")
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "Project",
        terminals: [first, second],
        panes: [
            MobilePanePreview(id: "pane-right", spatialIndex: 1, terminalIDs: [second.id]),
            MobilePanePreview(id: "pane-left", spatialIndex: 0, isFocused: true, terminalIDs: [first.id]),
        ],
        focusedPaneID: "pane-left",
        selectedTerminalID: first.id
    )

    #expect(workspace.resolvedPanes.map(\.id) == ["pane-left", "pane-right"])
    #expect(workspace.terminalCreationPaneID == "pane-left")
    #expect(workspace.terminals(in: "pane-right").map(\.id) == [second.id])
}

@Test func olderFlatPayloadGetsOneDeterministicCompatibilityPane() {
    let terminal = MobileTerminalPreview(id: "terminal-a", name: "shell")
    let workspace = MobileWorkspacePreview(id: "workspace", name: "Project", terminals: [terminal])

    #expect(workspace.resolvedPanes.count == 1)
    #expect(workspace.resolvedPanes[0].id.rawValue == "workspace-legacy-pane")
    #expect(workspace.resolvedPanes[0].terminalIDs == [terminal.id])
    #expect(workspace.hasCoherentTerminalReorderMembership)
}

@Test func flatPayloadWithExplicitPaneOwnershipRequiresRefreshBeforeReorder() {
    let terminal = MobileTerminalPreview(
        id: "terminal-a",
        name: "shell",
        paneID: "pane-not-reported"
    )
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "Project",
        terminals: [terminal]
    )

    #expect(!workspace.hasCoherentTerminalReorderMembership)
}

@Test func reorderIntentRejectsCrossPaneAndStaleSourceIdentity() {
    let pane = MobilePanePreview(
        id: "pane-left",
        spatialIndex: 0,
        terminalIDs: ["terminal-a", "terminal-b"]
    )

    let downward = MobileTerminalReorderIntent(
        terminalID: "terminal-a",
        sourceIndex: 0,
        destinationIndex: 2,
        pane: pane
    )
    #expect(downward?.targetIndex == 1)
    #expect(MobileTerminalReorderIntent(
        terminalID: "terminal-a",
        sourceIndex: 0,
        destinationIndex: 1,
        pane: pane
    ) == nil)
    #expect(MobileTerminalReorderIntent(
        terminalID: "terminal-from-other-pane",
        sourceIndex: 0,
        destinationIndex: 1,
        pane: pane
    ) == nil)
}

@Test func closeFallbackSelectsSameIndexThenPrevious() {
    let fallback = MobileTerminalCloseFallback(
        closedTerminalID: "terminal-b",
        selectedTerminalID: "terminal-b",
        orderedTerminalIDs: ["terminal-a", "terminal-b", "terminal-c"]
    )
    #expect(fallback.resolvedSelection(availableTerminalIDs: ["terminal-a", "terminal-c"]) == "terminal-c")

    let closingLast = MobileTerminalCloseFallback(
        closedTerminalID: "terminal-c",
        selectedTerminalID: "terminal-c",
        orderedTerminalIDs: ["terminal-a", "terminal-b", "terminal-c"]
    )
    #expect(closingLast.resolvedSelection(availableTerminalIDs: ["terminal-a", "terminal-b"]) == "terminal-b")
}

@Test func closeFallbackPreservesUnrelatedSelectionOnFailureOrRemoteRemoval() {
    let fallback = MobileTerminalCloseFallback(
        closedTerminalID: "terminal-b",
        selectedTerminalID: "terminal-a",
        orderedTerminalIDs: ["terminal-a", "terminal-b"]
    )
    #expect(fallback.resolvedSelection(availableTerminalIDs: ["terminal-a", "terminal-b"]) == "terminal-a")
    #expect(fallback.resolvedSelection(availableTerminalIDs: ["terminal-b"]) == nil)
}

@Test func closeFallbackPreservesSelectionMadeWhileCloseWasInFlight() {
    let fallback = MobileTerminalCloseFallback(
        closedTerminalID: "terminal-b",
        selectedTerminalID: "terminal-b",
        orderedTerminalIDs: ["terminal-a", "terminal-b", "terminal-c"]
    )

    #expect(fallback.resolvedSelection(
        currentSelection: "terminal-a",
        availableTerminalIDs: ["terminal-a", "terminal-c"]
    ) == "terminal-a")
}
