import CmuxFleet
import Foundation
import Testing

@Suite("Fleet board projection")
struct FleetBoardProjectionTests {
    @Test
    func allTaskStatesMapToOneColumn() {
        let columns = FleetTaskState.allCases.map { FleetBoardProjection.column(for: $0) }

        #expect(columns.count == FleetTaskState.allCases.count)
        #expect(columns[0] == .queue)
        #expect(Set(columns).isSubset(of: Set(FleetBoardColumn.allCases)))
        #expect(FleetBoardProjection.column(for: .queued) == .queue)
        #expect(FleetBoardProjection.column(for: .provisioning) == .running)
        #expect(FleetBoardProjection.column(for: .launching) == .running)
        #expect(FleetBoardProjection.column(for: .running) == .running)
        #expect(FleetBoardProjection.column(for: .stalled) == .running)
        #expect(FleetBoardProjection.column(for: .retryBackoff) == .running)
        #expect(FleetBoardProjection.column(for: .needsInput) == .needsInput)
        #expect(FleetBoardProjection.column(for: .awaitingReview) == .review)
        #expect(FleetBoardProjection.column(for: .done) == .done)
        #expect(FleetBoardProjection.column(for: .failed) == .done)
        #expect(FleetBoardProjection.column(for: .cancelled) == .done)
    }

    @Test
    func rowOrderingAndActionPredicatesUseEngineRules() {
        let config = Self.config(id: "fleet-a", name: "Fleet A")
        let newer = FleetTestSupport.task(
            idSuffix: "newer",
            state: .failed,
            attempts: 2,
            updatedAt: Date(timeIntervalSince1970: 200),
            pr: FleetPullRequestStatus(number: 123, url: URL(string: "https://example.com/pull/123")),
            lastError: "boom"
        )
        let older = FleetTestSupport.task(
            idSuffix: "older",
            state: .done,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let snapshot = FleetBoardProjection.makeSnapshot(
            configs: [config],
            isRunningByID: [config.id: true],
            tasksByFleetID: [config.id: [older, newer]],
            selectedFleetID: config.id
        )
        let doneRows = snapshot.columns[.done] ?? []

        #expect(snapshot.selectedFleet?.id == config.id)
        #expect(snapshot.selectedFleet?.isRunning == true)
        #expect(doneRows.map(\.id) == [newer.id, older.id])
        #expect(doneRows.first?.canRetry == true)
        #expect(doneRows.first?.canCancel == false)
        #expect(doneRows.first?.prLabel == "#123")
        #expect(doneRows.first?.hasWorkspace == true)
    }

    @Test
    func snapshotBuildsMultipleFleetPickerAndSelectedRows() {
        let a = Self.config(id: "fleet-a", name: "A Fleet")
        let b = Self.config(id: "fleet-b", name: "B Fleet")
        let selectedTask = FleetTestSupport.task(idSuffix: "selected", state: .needsInput)
        let otherTask = FleetTestSupport.task(idSuffix: "other", state: .queued)

        let snapshot = FleetBoardProjection.makeSnapshot(
            configs: [b, a],
            isRunningByID: [a.id: false, b.id: true],
            tasksByFleetID: [
                a.id: [otherTask],
                b.id: [selectedTask],
            ],
            selectedFleetID: b.id
        )

        #expect(snapshot.fleets.map(\.id) == [a.id, b.id])
        #expect(snapshot.selectedFleet?.id == b.id)
        #expect(snapshot.selectedFleet?.isRunning == true)
        #expect(snapshot.columns[.needsInput]?.map(\.id) == [selectedTask.id])
        #expect(snapshot.columns[.queue]?.isEmpty == true)
    }

    @Test(arguments: FleetTaskState.allCases)
    func actionPredicatesMatchUserActionStates(state: FleetTaskState) {
        #expect(state.canUserRetry == [.failed, .cancelled, .awaitingReview].contains(state))
        #expect(state.canUserCancel == !state.isTerminal)
    }

    private static func config(id: FleetID, name: String) -> FleetConfig {
        FleetConfig(id: id, name: name, repoRoot: "/repo", workspaceRoot: "/repo-fleet")
    }
}
