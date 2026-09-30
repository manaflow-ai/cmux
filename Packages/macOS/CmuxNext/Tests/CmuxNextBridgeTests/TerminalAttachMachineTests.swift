import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextBridge

/// Table tests for the terminal attach lifecycle (state-audit.md T3-T5).
struct TerminalAttachMachineTests {
    typealias Machine = TerminalAttachMachine<Int>

    static let initial = CellSize(cols: 80, rows: 24)
    static let wide = CellSize(cols: 120, rows: 40)
    static let narrow = CellSize(cols: 60, rows: 20)

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// A machine that attached on link `link` and delivered its replay.
    private func live(link: Int = 7, size: CellSize? = wide, visible: Bool = true) -> Machine {
        var machine = Machine(initialSize: Self.initial, visible: visible)
        _ = machine.reduce(.start)
        if let size { _ = machine.reduce(.resize(size)) }
        _ = machine.reduce(.opened(link, attempt: 1))
        _ = machine.reduce(.replayDelivered(link))
        return machine
    }

    @Test func startOpensAtTheInitialSizeOnce() {
        var machine = Machine(initialSize: Self.initial)
        #expect(machine.reduce(.start) == [.open(attempt: 1, size: Self.initial)])
        #expect(machine.reduce(.start) == [])
        #expect(machine.phase == .attaching(.init(attempt: 1, failures: 1, size: Self.initial, link: nil)))
    }

    @Test func startOpensAtTheLatestSettledSize() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.resize(Self.narrow))
        #expect(machine.reduce(.start) == [.open(attempt: 1, size: Self.narrow)])
    }

    // T3: input during the attach is queued and flushed once, in order, after the replay.
    @Test func inputTypedWhileAttachingIsFlushedInOrderAfterTheReplay() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        #expect(machine.reduce(.input(bytes("a"))) == [])
        #expect(machine.reduce(.opened(3, attempt: 1)) == [])
        #expect(machine.reduce(.input(bytes("b"))) == [])
        let flush = machine.reduce(.replayDelivered(3))
        #expect(flush == [.send(3, bytes("a")), .send(3, bytes("b"))])
        #expect(machine.queuedInput.isEmpty)
        #expect(machine.reduce(.input(bytes("c"))) == [.send(3, bytes("c"))])
        // A duplicate replay notification sends nothing twice.
        #expect(machine.reduce(.replayDelivered(3)) == [])
    }

    @Test func inputBeforeStartIsKept() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.input(bytes("x")))
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(1, attempt: 1))
        #expect(machine.reduce(.replayDelivered(1)) == [.send(1, bytes("x"))])
    }

    @Test func inputOverTheQueueCapIsDroppedAndCounted() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        let big = Data(count: Machine.maxQueuedInputBytes)
        _ = machine.reduce(.input(big))
        _ = machine.reduce(.input(bytes("late")))
        #expect(machine.queuedInputBytes == Machine.maxQueuedInputBytes)
        #expect(machine.droppedInputBytes == 4)
    }

    // T4: geometry during the attach is coalesced and applied after the replay.
    @Test func resizesDuringTheAttachCoalesceToTheLatestAfterTheReplay() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        #expect(machine.reduce(.resize(Self.wide)) == [])
        _ = machine.reduce(.opened(4, attempt: 1))
        #expect(machine.reduce(.resize(Self.narrow)) == [])
        _ = machine.reduce(.input(bytes("ls\r")))
        // Geometry first (the program sees the right width), then the input.
        #expect(machine.reduce(.replayDelivered(4)) == [.claim(4, Self.narrow), .send(4, bytes("ls\r"))])
        #expect(machine.claimed)
        #expect(machine.reportedSize == Self.narrow)
    }

    @Test func aHiddenViewNeverClaimsUntilShown() {
        var machine = live(visible: false)
        #expect(!machine.claimed)
        #expect(machine.reduce(.resize(Self.narrow)) == [])
        #expect(machine.reduce(.visibility(true)) == [.claim(7, Self.narrow)])
        #expect(machine.reduce(.visibility(false)) == [.release(7)])
        #expect(machine.reduce(.visibility(false)) == [])
        // Shown again: report and claim again.
        #expect(machine.reduce(.visibility(true)) == [.claim(7, Self.narrow)])
    }

    @Test func liveResizesReportOnlyChanges() {
        var machine = live()
        #expect(machine.claimed)
        #expect(machine.reduce(.resize(Self.wide)) == [])
        #expect(machine.reduce(.resize(Self.narrow)) == [.resize(7, Self.narrow)])
        #expect(machine.reduce(.resize(CellSize(cols: 0, rows: 3))) == [])
    }

    @Test func visibleWithoutASizeClaimsOnTheFirstReport() {
        var machine = live(size: nil)
        #expect(!machine.claimed)
        #expect(machine.reduce(.resize(Self.wide)) == [.claim(7, Self.wide)])
    }

    // Overflow: detach the old link, reattach, queue input until the new replay.
    @Test func overflowDetachesAndReattachesWithQueuedInput() {
        var machine = live()
        let effects = machine.reduce(.ended(7, .overflow))
        #expect(effects == [.detach(7), .open(attempt: 2, size: Self.wide)])
        #expect(machine.reduce(.input(bytes("q"))) == [])
        _ = machine.reduce(.resize(Self.narrow))
        _ = machine.reduce(.opened(8, attempt: 2))
        #expect(machine.reduce(.replayDelivered(8)) == [.claim(8, Self.narrow), .send(8, bytes("q"))])
        #expect(machine.liveLink == 8)
    }

    @Test func aStaleLinkEndingIsIgnored() {
        var machine = live()
        _ = machine.reduce(.ended(7, .overflow))
        #expect(machine.reduce(.ended(7, .detachedByClient)) == [])
        #expect(machine.reduce(.replayDelivered(7)) == [])
    }

    @Test func consecutiveOverflowsGiveUpAfterTheLimit() {
        var machine = live()
        var link = 7
        var effects = machine.reduce(.ended(link, .overflow))
        var reattaches = 0
        while case .open(let attempt, _) = effects.last {
            reattaches += 1
            link += 1
            _ = machine.reduce(.opened(link, attempt: attempt))
            effects = machine.reduce(.ended(link, .overflow))
        }
        #expect(reattaches == Machine.maxAttempts)
        #expect(effects == [.detach(link), .finish])
        #expect(machine.isClosed)
    }

    @Test func reachingLiveResetsTheFailureCount() {
        var machine = live()
        for step in 0..<(Machine.maxAttempts * 2) {
            let effects = machine.reduce(.ended(7 + step, .overflow))
            guard case .open(let attempt, _) = effects.last else {
                Issue.record("gave up after \(step) overflows that each reached live")
                return
            }
            _ = machine.reduce(.opened(8 + step, attempt: attempt))
            _ = machine.reduce(.replayDelivered(8 + step))
        }
        #expect(!machine.isClosed)
    }

    @Test func otherEndReasonsCloseAndFinish() {
        var machine = live()
        #expect(machine.reduce(.ended(7, .surfaceGone)) == [.detach(7), .finish])
        #expect(machine.reduce(.input(bytes("z"))) == [])
        #expect(machine.droppedInputBytes == 1)
    }

    @Test func openFailureClosesAndCountsQueuedInputAsDropped() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        _ = machine.reduce(.input(bytes("abc")))
        #expect(machine.reduce(.openFailed(attempt: 1)) == [.finish])
        #expect(machine.droppedInputBytes == 3)
        #expect(machine.reduce(.openFailed(attempt: 1)) == [])
    }

    // T5: closing during the attach cancels it and frees everything.
    @Test func closeWhileOpeningCancelsAndDetachesTheLateLink() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        _ = machine.reduce(.resize(Self.wide))
        #expect(machine.reduce(.close) == [.cancelOpen(attempt: 1), .finish])
        // The open completes anyway: its link is detached, never claimed.
        #expect(machine.reduce(.opened(9, attempt: 1)) == [.detach(9)])
        #expect(machine.reduce(.replayDelivered(9)) == [])
        #expect(machine.reduce(.resize(Self.narrow)) == [])
        #expect(machine.reduce(.visibility(false)) == [])
    }

    @Test func closeAwaitingTheReplayDetachesTheLink() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(5, attempt: 1))
        #expect(machine.reduce(.close) == [.detach(5), .finish])
        #expect(machine.reduce(.close) == [])
    }

    @Test func closeWhileReattachingCancelsTheNewOpen() {
        var machine = live()
        _ = machine.reduce(.ended(7, .overflow))
        #expect(machine.reduce(.close) == [.cancelOpen(attempt: 2), .finish])
        #expect(machine.reduce(.opened(8, attempt: 2)) == [.detach(8)])
    }

    @Test func closeBeforeStartOnlyFinishes() {
        var machine = Machine(initialSize: Self.initial)
        #expect(machine.reduce(.close) == [.finish])
        #expect(machine.reduce(.start) == [])
    }

    @Test func aSupersededOpenCompletionIsDetached() {
        var machine = live()
        _ = machine.reduce(.ended(7, .overflow))
        // attempt 1 is long gone; a late duplicate completion must not be adopted.
        #expect(machine.reduce(.opened(99, attempt: 1)) == [.detach(99)])
        #expect(machine.reduce(.openFailed(attempt: 1)) == [])
    }
}
