import CmuxMobileShellModel
import Foundation

struct TerminalHierarchyMutationProfilingSnapshotState {
    let terminalIDs: Set<MobileTerminalPreview.ID>
    let selectedTerminalIDs: Set<MobileTerminalPreview.ID>
    let terminalIDsByPane: [MobilePanePreview.ID: [MobileTerminalPreview.ID]]

    init(
        terminalIDs: Set<MobileTerminalPreview.ID>,
        selectedTerminalIDs: Set<MobileTerminalPreview.ID>,
        terminalIDsByPane: [MobilePanePreview.ID: [MobileTerminalPreview.ID]]
    ) {
        self.terminalIDs = terminalIDs
        self.selectedTerminalIDs = selectedTerminalIDs
        self.terminalIDsByPane = terminalIDsByPane
    }

    init(snapshot: TerminalHierarchySnapshot) {
        let rows = snapshot.panes.flatMap(\.rows)
        terminalIDs = Set(rows.map(\.id))
        selectedTerminalIDs = Set(rows.filter(\.isSelected).map(\.id))
        terminalIDsByPane = Dictionary(
            uniqueKeysWithValues: snapshot.panes.map { ($0.id, $0.rows.map(\.id)) }
        )
    }
}

struct TerminalHierarchyMutationProfilingPending {
    enum Operation {
        case create(baselineTerminalIDs: Set<MobileTerminalPreview.ID>)
        case reorder(
            paneID: MobilePanePreview.ID,
            expectedTerminalIDs: [MobileTerminalPreview.ID]
        )
        case close(
            terminalID: MobileTerminalPreview.ID,
            paneID: MobilePanePreview.ID,
            expectedTerminalIDs: [MobileTerminalPreview.ID],
            expectedSelectedTerminalID: MobileTerminalPreview.ID?
        )

        init?(
            closing terminalID: MobileTerminalPreview.ID,
            snapshot: TerminalHierarchySnapshot
        ) {
            guard let pane = snapshot.panes.first(where: { pane in
                pane.rows.contains(where: { $0.id == terminalID })
            }) else { return nil }
            let allRows = snapshot.panes.flatMap(\.rows)
            let selectedTerminalID = allRows.first(where: \.isSelected)?.id
            let orderedTerminalIDs = pane.rows.map(\.id)
            let survivingTerminalIDs = allRows.map(\.id).filter { $0 != terminalID }
            let fallback = MobileTerminalCloseFallback(
                closedTerminalID: terminalID,
                selectedTerminalID: selectedTerminalID,
                orderedTerminalIDs: orderedTerminalIDs
            )
            let expectedSelectedTerminalID = fallback.resolvedSelection(
                availableTerminalIDs: Set(survivingTerminalIDs)
            ) ?? survivingTerminalIDs.first
            self = .close(
                terminalID: terminalID,
                paneID: pane.id,
                expectedTerminalIDs: orderedTerminalIDs.filter { $0 != terminalID },
                expectedSelectedTerminalID: expectedSelectedTerminalID
            )
        }
    }

    let generation: UUID
    let interval: MobileInteractionProfilingSignposts.Interval?
    let operation: Operation
    var authoritativeSuccess = false

    func isReady(in snapshot: TerminalHierarchySnapshot) -> Bool {
        isReady(in: TerminalHierarchyMutationProfilingSnapshotState(snapshot: snapshot))
    }

    func isReady(in state: TerminalHierarchyMutationProfilingSnapshotState) -> Bool {
        guard authoritativeSuccess else { return false }
        switch operation {
        case .create(let baselineTerminalIDs):
            let addedTerminalIDs = state.terminalIDs.subtracting(baselineTerminalIDs)
            guard addedTerminalIDs.count == 1,
                  state.terminalIDs == baselineTerminalIDs.union(addedTerminalIDs) else { return false }
            return state.selectedTerminalIDs == addedTerminalIDs
        case .reorder(let paneID, let expectedTerminalIDs):
            return state.terminalIDsByPane[paneID] == expectedTerminalIDs
        case .close(
            let terminalID,
            let paneID,
            let expectedTerminalIDs,
            let expectedSelectedTerminalID
        ):
            let expectedSelectedTerminalIDs = expectedSelectedTerminalID.map { Set([$0]) } ?? []
            return !state.terminalIDs.contains(terminalID)
                && state.selectedTerminalIDs == expectedSelectedTerminalIDs
                && (state.terminalIDsByPane[paneID] ?? []) == expectedTerminalIDs
        }
    }
}
