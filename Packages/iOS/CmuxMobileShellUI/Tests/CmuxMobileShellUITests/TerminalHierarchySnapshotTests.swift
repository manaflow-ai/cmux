import CmuxMobileShell
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

@Test func closeConfirmationActionRetainsExactPayloadAfterDialogDismissal() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace-close-confirmation",
        name: "Close confirmation",
        terminals: [
            MobileTerminalPreview(
                id: "terminal-stable-id",
                name: "Agent",
                requiresCloseConfirmation: true
            ),
        ]
    )
    let row = try #require(
        TerminalHierarchySnapshot(
            workspace: workspace,
            selectedTerminalID: "terminal-stable-id"
        ).panes.first?.rows.first
    )
    var pendingConfirmation: TerminalHierarchyCloseConfirmation? = .init(
        row: row,
        confirmed: true
    )
    var capturedConfirmation: TerminalHierarchyCloseConfirmation?
    let action = try #require(pendingConfirmation).action {
        capturedConfirmation = $0
    }

    pendingConfirmation = nil
    action()

    #expect(pendingConfirmation == nil)
    #expect(capturedConfirmation?.row.id == "terminal-stable-id")
    #expect(capturedConfirmation?.confirmed == true)
}

@MainActor
@Test func confirmedCloseReportsUnavailableWhenAnotherMutationOwnsTheGate() throws {
    let workspace = MobileWorkspacePreview(
        id: "workspace-close-owner",
        name: "Close owner",
        terminals: [
            MobileTerminalPreview(id: "terminal-close", name: "Shell", paneID: "pane-close"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-close",
                spatialIndex: 0,
                terminalIDs: ["terminal-close"]
            ),
        ]
    )
    let snapshot = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil)
    let reorderGate = MobileTerminalReorderGate()
    let competingReservation = try #require(reorderGate.reserve(
        workspaceID: workspace.id,
        paneID: "pane-close"
    ))
    defer { reorderGate.finish(competingReservation) }

    let decision = TerminalHierarchyCloseReservationDecision(
        terminalID: "terminal-close",
        snapshot: snapshot,
        reorderGate: reorderGate
    )

    #expect(decision == .unavailable)
}

@Test func closeProtectedFailureUsesPinnedTerminalPresentation() {
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.protected(hostDisplayName: "Test Mac"))
    ) == .protected)
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.notConnected(hostDisplayName: "Test Mac"))
    ) == .failed)
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.confirmationRequired(hostDisplayName: "Test Mac"))
    ) == .confirmationRequired)
}

@Test func closeAmbiguousResultDistinguishesRefreshedFromRefreshRequired() {
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.resultUnknownRefreshed(hostDisplayName: "Test Mac"))
    ) == .resultUnknownRefreshed)
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.resultUnknownNeedsRefresh(hostDisplayName: "Test Mac"))
    ) == .resultUnknownNeedsRefresh)
    #expect(TerminalHierarchyCloseResultPresentation(
        .failure(.rejected(hostDisplayName: "Test Mac"))
    ) == .failed)
}

@Test func creationResultPresentationMapsEveryActionableFailure() {
    #expect(TerminalHierarchyCreationResultPresentation(.success(())) == .created)
    #expect(TerminalHierarchyCreationResultPresentation(
        .failure(.appliedNeedsRefresh(hostDisplayName: "Test Mac"))
    ) == .appliedNeedsRefresh)
    #expect(TerminalHierarchyCreationResultPresentation(
        .failure(.resultUnknownNeedsRefresh(hostDisplayName: "Test Mac"))
    ) == .resultUnknownNeedsRefresh)
    #expect(TerminalHierarchyCreationResultPresentation(
        .failure(.resultUnknownRefreshed(hostDisplayName: "Test Mac"))
    ) == .resultUnknownRefreshed)
    #expect(TerminalHierarchyCreationResultPresentation(
        .failure(.busy(hostDisplayName: "Test Mac"))
    ) == .failed)
    #expect(TerminalHierarchyCreationResultPresentation(
        .failure(.rejected(hostDisplayName: "Test Mac"))
    ) == .failed)
}

@Test func moveResultPresentationMapsEveryActionOutcome() {
    #expect(TerminalHierarchyMoveResultPresentation(.unavailable) == .unavailable)
    #expect(TerminalHierarchyMoveResultPresentation(.completed(.success(()))) == .reordered)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.appliedNeedsRefresh(hostDisplayName: "Test Mac")))
    ) == .appliedNeedsRefresh)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.resultUnknownNeedsRefresh(hostDisplayName: "Test Mac")))
    ) == .resultUnknownNeedsRefresh)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.resultUnknownRefreshed(hostDisplayName: "Test Mac")))
    ) == .resultUnknownRefreshed)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.protected(hostDisplayName: "Test Mac")))
    ) == .protected)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.notConnected(hostDisplayName: "Test Mac")))
    ) == .failed)
    #expect(TerminalHierarchyMoveResultPresentation(
        .completed(.failure(.confirmationRequired(hostDisplayName: "Test Mac")))
    ) == .failed)
}

@MainActor
@Test func workspaceAmbiguousRefreshedResultUsesVerificationCopy() {
    let view = WorkspaceShellView(store: MobileShellComposite.preview(), signOut: {})

    #expect(view.workspaceActionFailureMessage(
        action: .renameWorkspace,
        failure: .resultUnknownRefreshed(hostDisplayName: "Test Mac")
    ) == "Latest workspace state loaded. Verify the change.")
    #expect(view.workspaceActionFailureMessage(
        action: .renameWorkspace,
        failure: .rejected(hostDisplayName: nil)
    ).contains("Couldn't rename workspace"))
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

@Test func hierarchySnapshotDisablesReorderUntilMissingMembershipRefreshes() throws {
    var workspace = MobileWorkspacePreview(
        id: "workspace-missing-membership",
        name: "Missing membership",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-d", name: "D", paneID: "pane-a"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-a",
                spatialIndex: 0,
                terminalIDs: ["terminal-a", "terminal-missing", "terminal-b", "terminal-d"]
            ),
        ]
    )
    workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalReorderActions: true
    )

    let malformed = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil)
    #expect(malformed.panes.first?.rows.map(\.id) == ["terminal-a", "terminal-b", "terminal-d"])
    #expect(!malformed.canReorder)
    #expect(malformed.requiresReorderRefresh)

    workspace.panes[0].terminalIDs = ["terminal-a", "terminal-b", "terminal-d"]
    let refreshed = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil)
    #expect(refreshed.canReorder)
    #expect(!refreshed.requiresReorderRefresh)
}

@Test func hierarchySnapshotDisablesReorderForDuplicateBeforeVisibleSource() {
    var workspace = MobileWorkspacePreview(
        id: "workspace-duplicate-before-source",
        name: "Duplicate before source",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-d", name: "D", paneID: "pane-a"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-a",
                spatialIndex: 0,
                terminalIDs: ["terminal-a", "terminal-a", "terminal-b", "terminal-d"]
            ),
        ]
    )
    workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalReorderActions: true
    )

    let snapshot = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil)
    #expect(snapshot.panes.first?.rows.map(\.id) == ["terminal-a", "terminal-b", "terminal-d"])
    #expect(!snapshot.canReorder)
    #expect(snapshot.requiresReorderRefresh)
}

@Test func hierarchySnapshotDisablesReorderForCrossPaneMembership() {
    var workspace = MobileWorkspacePreview(
        id: "workspace-cross-pane-membership",
        name: "Cross-pane membership",
        terminals: [
            MobileTerminalPreview(id: "terminal-a", name: "A", paneID: "pane-a"),
            MobileTerminalPreview(id: "terminal-b", name: "B", paneID: "pane-b"),
        ],
        panes: [
            MobilePanePreview(
                id: "pane-a",
                spatialIndex: 0,
                terminalIDs: ["terminal-a", "terminal-b"]
            ),
            MobilePanePreview(
                id: "pane-b",
                spatialIndex: 1,
                terminalIDs: ["terminal-b"]
            ),
        ]
    )
    workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalReorderActions: true
    )

    let snapshot = TerminalHierarchySnapshot(workspace: workspace, selectedTerminalID: nil)
    #expect(!snapshot.canReorder)
    #expect(snapshot.requiresReorderRefresh)
}
