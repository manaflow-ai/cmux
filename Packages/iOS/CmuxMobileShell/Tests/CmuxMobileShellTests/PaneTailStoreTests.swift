import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite
struct PaneTailStoreTests {
    @Test func fullFramePublishesLastThreeNonBlankRowsAndRequestsBootstrap() throws {
        let clock = PaneTailTestClock(Date(timeIntervalSince1970: 100))
        let requester = RecordingPaneTailReplayRequester()
        let store = makeStore(clock: clock)
        store.installReplayRequester(requester)
        store.setInterest(["surface-1"])

        #expect(requester.surfaceIDs == ["surface-1"])
        #expect(store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 1,
            rows: 6,
            spans: [
                .init(row: 0, column: 0, text: "old"),
                .init(row: 1, column: 0, text: "alpha   "),
                .init(row: 3, column: 0, text: "beta"),
                .init(row: 4, column: 0, text: "gamma"),
            ]
        )))
        #expect(store.tails["surface-1"]?.rows == ["alpha", "beta", "gamma"])
        #expect(store.tails["surface-1"]?.columns == 20)
        #expect(store.tails["surface-1"]?.lastActivityAt == clock.date)
    }

    @Test func deltaMergesRowSpansClearsRowsAndFullFrameResets() throws {
        let clock = PaneTailTestClock(Date(timeIntervalSince1970: 200))
        let store = makeStore(clock: clock)
        store.setInterest(["surface-1"])
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 1,
            rows: 4,
            spans: [
                .init(row: 0, column: 0, text: "zero"),
                .init(row: 1, column: 0, text: "one"),
                .init(row: 2, column: 0, text: "two"),
                .init(row: 3, column: 0, text: "three"),
            ]
        ))

        clock.advance(by: 0.1)
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 2,
            rows: 4,
            full: false,
            clearedRows: [1, 3],
            spans: [.init(row: 1, column: 0, text: "ONE")]
        ))
        #expect(store.tails["surface-1"]?.rows == ["zero", "ONE", "two"])

        clock.advance(by: 0.1)
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 3,
            rows: 2,
            spans: [.init(row: 0, column: 0, text: "reset")]
        ))
        #expect(store.tails["surface-1"]?.rows == ["reset"])
    }

    @Test func interestRemovalDropsStateAndFutureFrames() throws {
        let clock = PaneTailTestClock(Date(timeIntervalSince1970: 300))
        let store = makeStore(clock: clock)
        store.setInterest(["surface-1"])
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 1,
            rows: 1,
            spans: [.init(row: 0, column: 0, text: "visible")]
        ))
        store.setInterest([])
        #expect(store.tails["surface-1"] == nil)
        #expect(!store.isInterested(in: "surface-1"))
        #expect(!store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 2,
            rows: 1,
            spans: [.init(row: 0, column: 0, text: "ignored")]
        )))
    }

    @Test func peekBudgetAndThrottlePublishAtMostTenHertz() throws {
        let clock = PaneTailTestClock(Date(timeIntervalSince1970: 400))
        let store = makeStore(clock: clock)
        store.setInterest(["surface-1"])
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 1,
            rows: 5,
            spans: (0..<5).map { .init(row: $0, column: 0, text: "row-\($0)") }
        ))
        #expect(store.tails["surface-1"]?.rows == ["row-2", "row-3", "row-4"])

        clock.advance(by: 0.051)
        store.setPeekBudget(surfaceID: "surface-1", rows: 5)
        #expect(store.tails["surface-1"]?.rows == ["row-2", "row-3", "row-4"])
        clock.advance(by: 0.05)
        store.flushPendingPublications()
        #expect(store.tails["surface-1"]?.rows == ["row-0", "row-1", "row-2", "row-3", "row-4"])

        store.setPeekBudget(surfaceID: "surface-1", rows: 3)
        clock.advance(by: 0.101)
        store.flushPendingPublications()
        #expect(store.tails["surface-1"]?.rows == ["row-2", "row-3", "row-4"])
    }

    @Test func activityTimestampNeverMovesBackwardAcrossDeliveredFrames() throws {
        let clock = PaneTailTestClock(Date(timeIntervalSince1970: 500))
        let store = makeStore(clock: clock)
        store.setInterest(["surface-1"])
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 1,
            rows: 1,
            spans: [.init(row: 0, column: 0, text: "first")]
        ))
        let firstActivity = store.tails["surface-1"]?.lastActivityAt

        clock.date = Date(timeIntervalSince1970: 499)
        _ = store.apply(try frame(
            surfaceID: "surface-1",
            sequence: 2,
            rows: 1,
            spans: [.init(row: 0, column: 0, text: "second")]
        ))
        clock.date = Date(timeIntervalSince1970: 501)
        store.flushPendingPublications()
        #expect(store.tails["surface-1"]?.lastActivityAt == firstActivity)
    }

    private func makeStore(clock: PaneTailTestClock) -> PaneTailStore {
        PaneTailStore(
            now: { clock.date },
            sleep: { _ in throw CancellationError() }
        )
    }

    private func frame(
        surfaceID: String,
        sequence: UInt64,
        columns: Int = 20,
        rows: Int,
        full: Bool = true,
        clearedRows: [Int] = [],
        spans: [MobileTerminalRenderGridFrame.RowSpan]
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: sequence,
            columns: columns,
            rows: rows,
            full: full,
            clearedRows: clearedRows,
            rowSpans: spans
        )
    }
}
