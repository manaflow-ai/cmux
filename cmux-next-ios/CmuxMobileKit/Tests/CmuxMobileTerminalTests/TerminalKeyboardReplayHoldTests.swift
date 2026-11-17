import Foundation
import Testing
@testable import CmuxMobileTerminal

/// R1-1: the Mac's redraw at fewer rows waits for the keyboard to stop, and
/// nothing else can keep it waiting.
@Suite struct TerminalKeyboardReplayHoldTests {
    private let reset = TerminalKeyboardReplayHold.mirrorReset

    /// The keyboard rises over vim: 40 rows held, the page asks for 26.
    private func rising() -> TerminalKeyboardReplayHold {
        var hold = TerminalKeyboardReplayHold()
        hold.keyboardStarted()
        return hold
    }

    @Test func aShorterGridWhileTheKeyboardRisesWaitsForItToStop() {
        var hold = rising()
        let grid = hold.arrived(.hostGrid(columns: 53, rows: 26), isTUI: true, heldRows: 40, pageRows: 26)
        #expect(grid.takeHeldFrame == false)
        #expect(hold.gridPending)
        // Its reset's held frame waits too (taken when it is fed).
        let resetArrived = hold.arrived(.output(reset), isTUI: true, heldRows: 40, pageRows: 26)
        #expect(resetArrived.takeHeldFrame == false)
        let holds = hold.holdsAt(nextIsGrid: true)
        #expect(holds)
        #expect(hold.holding)
        let stopped = hold.keyboardStopped()
        #expect(stopped == .init(resume: true, takeHeldFrame: true))
        #expect(!hold.holding && !hold.gridPending && !hold.resetDeferred)
        let holdsAgain = hold.holdsAt(nextIsGrid: true)
        #expect(!holdsAgain)
    }

    @Test func bytesBeforeTheGridAreNotHeld() {
        var hold = rising()
        _ = hold.arrived(.hostGrid(columns: 53, rows: 26), isTUI: true, heldRows: 40, pageRows: 26)
        // An echo queued ahead of the grid change goes out.
        let atEcho = hold.holdsAt(nextIsGrid: false)
        #expect(!atEcho)
        let atGrid = hold.holdsAt(nextIsGrid: true)
        #expect(atGrid)
    }

    @Test func aTallerGridOrAStillKeyboardIsNotHeld() {
        var hiding = rising()
        // Keyboard hiding: 26 held, 40 asked; the taller grid swaps in at once.
        _ = hiding.arrived(.hostGrid(columns: 53, rows: 40), isTUI: true, heldRows: 26, pageRows: 40)
        #expect(!hiding.gridPending)
        let hidingReset = hiding.arrived(.output(reset), isTUI: true, heldRows: 26, pageRows: 40)
        #expect(hidingReset.takeHeldFrame)
        var still = TerminalKeyboardReplayHold()
        _ = still.arrived(.hostGrid(columns: 53, rows: 26), isTUI: true, heldRows: 40, pageRows: 26)
        #expect(!still.gridPending)
        // A shell, or another device's grid (not the page's rows): not held.
        var shell = rising()
        _ = shell.arrived(.hostGrid(columns: 53, rows: 26), isTUI: false, heldRows: 40, pageRows: 26)
        var other = rising()
        _ = other.arrived(.hostGrid(columns: 53, rows: 20), isTUI: true, heldRows: 40, pageRows: 26)
        #expect(!shell.gridPending && !other.gridPending)
    }

    /// A disconnect, a reattach, the process ending or the app leaving the
    /// alternate screen ends a hold at once, its held frame taken first.
    @Test(arguments: [TerminalSessionEvent.connection(.reattaching(mac: "mini")), .connection(.attached), .exited(code: 0), .alternateScreen(false)])
    func aLinkOrScreenChangeEndsTheHold(_ event: TerminalSessionEvent) {
        var hold = rising()
        _ = hold.arrived(.hostGrid(columns: 53, rows: 26), isTUI: true, heldRows: 40, pageRows: 26)
        _ = hold.arrived(.output(reset), isTUI: true, heldRows: 40, pageRows: 26)
        let holds = hold.holdsAt(nextIsGrid: true)
        #expect(holds)
        let ended = hold.arrived(event, isTUI: true, heldRows: 40, pageRows: 26)
        #expect(ended.release == .init(resume: true, takeHeldFrame: true))
        #expect(!hold.holding && !hold.gridPending && !hold.resetDeferred)
        // A later reset is not deferred by the old grid.
        let later = hold.arrived(.output(reset), isTUI: true, heldRows: 40, pageRows: 26)
        #expect(later.takeHeldFrame)
        // The keyboard's stop has nothing left to release.
        let stopped = hold.keyboardStopped()
        #expect(stopped == .none)
    }

    @Test func aResetBeforeTheQueueReachesTheGridIsReleasedByTheStop() {
        var hold = rising()
        _ = hold.arrived(.hostGrid(columns: 53, rows: 26), isTUI: true, heldRows: 40, pageRows: 26)
        _ = hold.arrived(.output(reset), isTUI: true, heldRows: 40, pageRows: 26)
        // The keyboard stopped before the queue got to the grid.
        let stopped = hold.keyboardStopped()
        #expect(stopped == .init(resume: false, takeHeldFrame: true))
        let holds = hold.holdsAt(nextIsGrid: true)
        #expect(!holds)
    }
}

/// A double toggle asks the Mac three times (28, 40, then 30 rows) and a
/// reversed one twice (30, then 40) before the first answer is drawn. Each
/// answer is a grid change, a mirror reset and a replay. Answers to a
/// resize older than the newest wait in the queue (stale), and the newest
/// answer drops them: only its grid is drawn.
@Suite struct TerminalOutputQueueAnswerTests {
    let reset = TerminalKeyboardReplayHold.mirrorReset

    private func steps(_ queue: inout TerminalOutputQueue) -> [TerminalOutputQueue.Step] {
        var out: [TerminalOutputQueue.Step] = []
        while let step = queue.next(budget: 1 << 20) { out.append(step) }
        return out
    }

    @Test func theNewestAnswerDropsTheStaleOnesBeforeIt() {
        var queue = TerminalOutputQueue()
        queue.append(Data("echo".utf8))
        queue.append(hostGrid: 53, rows: 28, stale: true)
        queue.append(reset)
        queue.append(Data("replay28".utf8))
        queue.append(alternateScreen: true)
        #expect(!queue.nextHostGridIsStale)
        _ = queue.next(budget: 1 << 20)
        #expect(queue.nextHostGridIsStale)
        queue.append(hostGrid: 53, rows: 40, stale: true)
        queue.append(reset)
        queue.append(Data("replay40".utf8))
        queue.append(hostGrid: 53, rows: 30)
        let dropped = queue.dropStaleAnswers()
        #expect(dropped == 2 * reset.count + 16)
        queue.append(reset)
        queue.append(Data("replay30".utf8))
        #expect(queue.pendingBytes == reset.count + 8)
        #expect(steps(&queue) == [.alternateScreen(true), .hostGrid(columns: 53, rows: 30), .bytes(reset + Data("replay30".utf8))])
    }

    @Test func aNewerResizeMakesQueuedAnswersStaleAndTheirWaitCanEnd() {
        var queue = TerminalOutputQueue()
        queue.append(hostGrid: 53, rows: 30)
        queue.append(reset)
        #expect(!queue.nextHostGridIsStale)
        queue.markGridsStale()
        #expect(queue.nextHostGridIsStale)
        // The newest answer never came: the queued ones go on in order.
        queue.clearStale()
        #expect(!queue.nextHostGridIsStale)
        #expect(steps(&queue) == [.hostGrid(columns: 53, rows: 30), .bytes(reset)])
    }

    @Test func aGridWithNoStaleAnswerBeforeItDropsNothing() {
        var queue = TerminalOutputQueue()
        queue.append(Data("echo".utf8))
        queue.append(hostGrid: 53, rows: 26)
        #expect(queue.dropStaleAnswers() == 0)
        queue.append(Data("live".utf8))
        queue.append(hostGrid: 53, rows: 30)
        #expect(queue.dropStaleAnswers() == 0)
        #expect(steps(&queue).count == 4)
    }
}
