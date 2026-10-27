#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextWakeups
import Testing

/// The awaited-low-priority check (plans/cmux-next/chrome-parity/p02-threads.md, section D, task 112): in Debug and
/// blocking-checks builds, the main thread awaiting a BackgroundWork item stated below `.userBlocking` while the main
/// task board runs input work records one `priority-inversion` site at the awaiting line, record only. An item
/// stated `.userBlocking`, an await outside an input turn and a post record nothing; Release builds compile the
/// check out, so this suite is empty there. Chrome: work a person waits for
/// is `TaskPriority::USER_BLOCKING` (base/task/task_traits.h).
@Suite(.serialized, .timeLimit(.minutes(1))) struct BackgroundWorkInversionTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The site is the awaiting line, counted without time; the item still runs and returns its value.
    @MainActor @Test func aBestEffortRunAwaitedInAnInputTurnRecordsOneSite() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.best-effort", inputTurns: board)
        let line: UInt = #line
        let value = try await Self.inInputTurn(board, table) {
            try await work.run(.bestEffort, mayBlock: .cpu, line: line) { 7 }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(value == 7)
        #expect(sites.map(\.kind) == [.priorityInversion])
        #expect(sites.map(\.context) == [.main])
        #expect(sites.map(\.location) == ["\(#fileID):\(line)"])
        #expect(sites.map(\.count) == [1])
        #expect(sites.map(\.totalNanos) == [0])
    }

    /// Every level below `.userBlocking` counts, and a repeat of the site adds to its count.
    @MainActor @Test func everyLevelBelowUserBlockingCountsAtItsSite() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.levels", inputTurns: board)
        try await Self.inInputTurn(board, table) {
            for priority in [WorkPriority.idle, .bestEffort, .userVisible] {
                try await work.run(priority, mayBlock: .cpu) {}
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.priorityInversion])
        #expect(sites.map(\.count) == [3])
    }

    @MainActor @Test func aUserBlockingRunInAnInputTurnRecordsNothing() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.user-blocking", inputTurns: board)
        try await Self.inInputTurn(board, table) {
            try await work.run(.userBlocking, mayBlock: .cpu) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @MainActor @Test func aBestEffortRunOutsideAnInputTurnRecordsNothing() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.outside", inputTurns: board)
        let visible = board.beginSpan(.visible, owner: board.internOwner("test.visible"), budgetNanos: 0, startNanos: 0)
        try await BlockingViolationTable.$scoped.withValue(table) {
            try await work.run(.bestEffort, mayBlock: .cpu) {}
        }
        board.endSpan(visible, nowNanos: 0)
        try await BlockingViolationTable.$scoped.withValue(table) {
            try await work.run(.bestEffort, mayBlock: .cpu) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// Nobody awaits a posted item, so posting low work from an input turn is the fix, not a site.
    @MainActor @Test func aBestEffortPostInAnInputTurnRecordsNothing() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.post", inputTurns: board)
        try await Self.inInputTurn(board, table) {
            work.post(.bestEffort, mayBlock: .cpu) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// A low host resolution awaited in an input turn is the same inversion.
    @MainActor @Test func aLowHostResolutionAwaitedInAnInputTurnRecordsOneSite() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.resolve", inputTurns: board)
        try await Self.inInputTurn(board, table) {
            try await work.resolveHost(.userVisible) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.priorityInversion])
    }

    /// An awaited sequence item is the same inversion, and a worse one: it also waits behind every item posted
    /// before it in the sequence. The site is the awaiting line.
    @MainActor @Test func aBestEffortSequenceRunAwaitedInAnInputTurnRecordsOneSite() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.sequence", inputTurns: board)
        let sequence = work.sequence("test.inversion.sequence")
        let line: UInt = #line
        let value = try await Self.inInputTurn(board, table) {
            try await sequence.run(.bestEffort, line: line) { 7 }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(value == 7)
        #expect(sites.map(\.kind) == [.priorityInversion])
        #expect(sites.map(\.location) == ["\(#fileID):\(line)"])
        #expect(sites.map(\.count) == [1])
    }

    @MainActor @Test func aUserBlockingSequenceRunInAnInputTurnRecordsNothing() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.sequence-user-blocking", inputTurns: board)
        let sequence = work.sequence("test.inversion.sequence-user-blocking")
        try await Self.inInputTurn(board, table) {
            try await sequence.run(.userBlocking) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The check is record only: a table in trap mode records the site and the process goes on.
    @MainActor @Test func trapModeRecordsTheSiteWithoutStopping() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .trap, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.trap", inputTurns: board)
        try await Self.inInputTurn(board, table) {
            try await work.run(.bestEffort, mayBlock: .cpu) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.priorityInversion])
        #expect(BlockingKind.priorityInversion.isRecordOnly)
    }

    /// With no board, BackgroundWork checks nothing (a test's or a tool's own lanes).
    @MainActor @Test func lanesWithNoBoardRecordNothing() async throws {
        let (board, table) = (MainTaskBoard(), BlockingViolationTable(mode: .record, poolMode: .record))
        let work = BackgroundWork(cpuWidth: 1, label: "test.inversion.no-board")
        try await Self.inInputTurn(board, table) {
            try await work.run(.bestEffort, mayBlock: .cpu) {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// Runs `body` on the main actor with an input span open on `board` and `table` as the checks' table.
    @MainActor
    private static func inInputTurn<T>(_ board: MainTaskBoard, _ table: BlockingViolationTable,
                                       _ body: () async throws -> T) async throws -> T {
        let span = board.beginSpan(.input, owner: board.internOwner("test.input"), budgetNanos: 0, startNanos: 0)
        defer { board.endSpan(span, nowNanos: 0) }
        return try await BlockingViolationTable.$scoped.withValue(table) { try await body() }
    }
    #endif
}
