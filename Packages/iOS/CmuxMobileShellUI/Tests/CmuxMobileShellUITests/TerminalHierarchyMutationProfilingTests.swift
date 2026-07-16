import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Test func mutationAffordancePolicyKeepsProfilingSettlementAsTheFence() {
    #expect(TerminalHierarchyMutationAffordancePolicy(
        reorderGateCanMutate: true,
        interactionProfilingIsActive: false,
        hasPendingMutationProfiling: true
    ).canMutate)
    #expect(!TerminalHierarchyMutationAffordancePolicy(
        reorderGateCanMutate: true,
        interactionProfilingIsActive: true,
        hasPendingMutationProfiling: true
    ).canMutate)
    #expect(TerminalHierarchyMutationAffordancePolicy(
        reorderGateCanMutate: true,
        interactionProfilingIsActive: true,
        hasPendingMutationProfiling: false
    ).canMutate)
    #expect(!TerminalHierarchyMutationAffordancePolicy(
        reorderGateCanMutate: false,
        interactionProfilingIsActive: false,
        hasPendingMutationProfiling: false
    ).canMutate)
}

@Test func createProfilingWaitsForAuthoritativeExactSelectedAddition() {
    let baseline: Set<MobileTerminalPreview.ID> = ["terminal-a", "terminal-b"]
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: .create(baselineTerminalIDs: baseline)
    )
    let created = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalID: "terminal-c"
    )

    #expect(!pending.isReady(in: created))
    pending.authoritativeSuccess = true
    #expect(pending.isReady(in: created))
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalID: "terminal-a"
    )))
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        selectedTerminalID: "terminal-c"
    )))
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c", "terminal-d"],
        selectedTerminalID: "terminal-c"
    )))
    #expect(!pending.isReady(in: TerminalHierarchyMutationProfilingSnapshotState(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalIDs: ["terminal-a", "terminal-c"],
        terminalIDsByPane: [
            "pane-left": ["terminal-a", "terminal-b", "terminal-c"],
        ]
    )))
}

@Test func reorderProfilingRequiresTheExactStableIDOrder() {
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: .reorder(
            paneID: "pane-left",
            expectedTerminalIDs: ["terminal-b", "terminal-a"]
        )
    )
    let reordered = mutationProfilingSnapshot(
        terminalIDs: ["terminal-b", "terminal-a"],
        selectedTerminalID: "terminal-a"
    )

    #expect(!pending.isReady(in: reordered))
    pending.authoritativeSuccess = true
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b"],
        selectedTerminalID: "terminal-a"
    )))
    #expect(pending.isReady(in: reordered))
}

@Test func closeProfilingSelectsTheSameIndexAndRejectsWrongSelection() throws {
    let before = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalID: "terminal-b"
    )
    let operation = try #require(TerminalHierarchyMutationProfilingPending.Operation(
        closing: "terminal-b",
        snapshot: before
    ))
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: operation
    )
    let closed = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        selectedTerminalID: "terminal-c"
    )

    #expect(!pending.isReady(in: closed))
    pending.authoritativeSuccess = true
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        selectedTerminalID: "terminal-a"
    )))
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-c", "terminal-a"],
        selectedTerminalID: "terminal-c"
    )))
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        otherPaneTerminalIDs: ["terminal-b"],
        selectedTerminalID: "terminal-c"
    )))
    #expect(pending.isReady(in: closed))
}

@Test func closeProfilingSelectsThePreviousTerminalAtTheEnd() throws {
    let before = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalID: "terminal-c"
    )
    let operation = try #require(TerminalHierarchyMutationProfilingPending.Operation(
        closing: "terminal-c",
        snapshot: before
    ))
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: operation
    )
    let closed = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b"],
        selectedTerminalID: "terminal-b"
    )

    #expect(!pending.isReady(in: closed))
    pending.authoritativeSuccess = true
    #expect(pending.isReady(in: closed))
}

@Test func closeProfilingPreservesAnUnrelatedSelection() throws {
    let before = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-b", "terminal-c"],
        selectedTerminalID: "terminal-a"
    )
    let operation = try #require(TerminalHierarchyMutationProfilingPending.Operation(
        closing: "terminal-b",
        snapshot: before
    ))
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: operation
    )
    let closed = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        selectedTerminalID: "terminal-a"
    )

    #expect(!pending.isReady(in: closed))
    pending.authoritativeSuccess = true
    #expect(!pending.isReady(in: mutationProfilingSnapshot(
        terminalIDs: ["terminal-a", "terminal-c"],
        selectedTerminalID: "terminal-c"
    )))
    #expect(pending.isReady(in: closed))
}

@Test func closeProfilingAllowsNoSelectionOnlyWithNoSurvivor() throws {
    let before = mutationProfilingSnapshot(
        terminalIDs: ["terminal-a"],
        selectedTerminalID: "terminal-a"
    )
    let operation = try #require(TerminalHierarchyMutationProfilingPending.Operation(
        closing: "terminal-a",
        snapshot: before
    ))
    var pending = TerminalHierarchyMutationProfilingPending(
        generation: UUID(),
        interval: nil,
        operation: operation
    )
    let closed = mutationProfilingSnapshot(terminalIDs: [], selectedTerminalID: nil)

    #expect(!pending.isReady(in: closed))
    pending.authoritativeSuccess = true
    #expect(pending.isReady(in: closed))
    #expect(!pending.isReady(in: TerminalHierarchyMutationProfilingSnapshotState(
        terminalIDs: [],
        selectedTerminalIDs: ["terminal-unexpected"],
        terminalIDsByPane: ["pane-left": []]
    )))
}

private func mutationProfilingSnapshot(
    terminalIDs: [MobileTerminalPreview.ID],
    otherPaneTerminalIDs: [MobileTerminalPreview.ID] = [],
    selectedTerminalID: MobileTerminalPreview.ID?
) -> TerminalHierarchySnapshot {
    let paneID: MobilePanePreview.ID = "pane-left"
    let otherPaneID: MobilePanePreview.ID = "pane-right"
    let workspace = MobileWorkspacePreview(
        id: "workspace",
        name: "Workspace",
        terminals: terminalIDs.map {
            MobileTerminalPreview(id: $0, name: $0.rawValue, paneID: paneID)
        } + otherPaneTerminalIDs.map {
            MobileTerminalPreview(id: $0, name: $0.rawValue, paneID: otherPaneID)
        },
        panes: [
            MobilePanePreview(
                id: paneID,
                spatialIndex: 0,
                isFocused: true,
                terminalIDs: terminalIDs
            ),
        ] + (otherPaneTerminalIDs.isEmpty ? [] : [
            MobilePanePreview(
                id: otherPaneID,
                spatialIndex: 1,
                isFocused: false,
                terminalIDs: otherPaneTerminalIDs
            ),
        ]),
        focusedPaneID: paneID,
        selectedTerminalID: selectedTerminalID
    )
    return TerminalHierarchySnapshot(
        workspace: workspace,
        selectedTerminalID: selectedTerminalID
    )
}
