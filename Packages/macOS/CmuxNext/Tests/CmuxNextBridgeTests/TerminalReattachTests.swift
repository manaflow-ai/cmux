import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextBridge

/// A view whose stream ended or whose attach failed is disconnected, never
/// closed: it re-attaches on the next event that can make an attach work
/// (shown again, a key press, a click or focus, the terminal or the
/// connection back). Coordinator decision after dogfood nxdog11.
struct TerminalReattachTests {
    typealias Machine = TerminalAttachMachine<Int>

    static let initial = CellSize(cols: 80, rows: 24)
    static let wide = CellSize(cols: 120, rows: 40)

    private func live(link: Int = 7) -> Machine {
        var machine = Machine(initialSize: Self.initial, visible: true)
        _ = machine.reduce(.start)
        _ = machine.reduce(.resize(Self.wide))
        _ = machine.reduce(.opened(link, attempt: 1))
        _ = machine.reduce(.replayDelivered(link))
        return machine
    }

    private func opens(_ effects: [Machine.Effect]) -> Bool {
        effects.contains { if case .open = $0 { true } else { false } }
    }

    @Test func aDetachedStreamDisconnectsInsteadOfClosing() {
        var machine = live()
        let effects = machine.reduce(.ended(7, .surfaceGone))
        #expect(effects.contains(.detach(7)))
        #expect(!effects.contains(.finish), "the view's stream must stay open for a re-attach")
        #expect(!machine.isClosed)
    }

    @Test func showingADisconnectedViewReattaches() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        _ = machine.reduce(.visibility(false))
        #expect(opens(machine.reduce(.visibility(true))))
    }

    @Test func focusOnADisconnectedViewReattaches() {
        var machine = live()
        _ = machine.reduce(.ended(7, .connectionLost("gone")))
        #expect(opens(machine.reduce(.focused)))
    }

    @Test func typingInADisconnectedViewReattachesAndSendsTheKeysAfterTheReplay() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        let effects = machine.reduce(.input(Data("ls\r".utf8)))
        guard case .open(let attempt, _)? = effects.first(where: { if case .open = $0 { true } else { false } }) else {
            Issue.record("typing did not re-attach: \(effects)")
            return
        }
        #expect(machine.droppedInputBytes == 0)
        _ = machine.reduce(.opened(8, attempt: attempt))
        #expect(machine.reduce(.replayDelivered(8)).contains(.send(8, Data("ls\r".utf8))))
    }

    @Test func aFailedAttachDisconnectsAndTheNextFocusTriesAgain() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        #expect(!machine.reduce(.openFailed(attempt: 1)).contains(.finish))
        #expect(!machine.isClosed)
        #expect(opens(machine.reduce(.focused)))
    }

    @Test func oneReattachAtATime() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        #expect(opens(machine.reduce(.focused)))
        #expect(!opens(machine.reduce(.focused)))
        #expect(!opens(machine.reduce(.input(Data("x".utf8)))))
    }
}

/// Status, backoff and exit rules of the disconnected view.
struct TerminalReattachRuleTests {
    typealias Machine = TerminalAttachMachine<Int>

    private func disconnected() -> Machine {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true)
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(7, attempt: 1))
        _ = machine.reduce(.replayDelivered(7))
        _ = machine.reduce(.ended(7, .surfaceGone))
        return machine
    }

    @Test func theViewIsToldDisconnectedReconnectingAndBack() {
        var machine = disconnected()
        #expect(machine.status == .disconnected(.streamEnded, reconnecting: false))
        let effects = machine.reduce(.focused)
        #expect(effects.first == .status(.disconnected(.streamEnded, reconnecting: true)))
        _ = machine.reduce(.opened(8, attempt: 2))
        #expect(machine.reduce(.replayDelivered(8)).first == .status(.connected))
        #expect(machine.liveLink == 8)
    }

    @Test func theFirstReattachIsImmediateAndOnlyAFailedOneBacksOff() {
        var machine = disconnected()
        #expect(machine.reduce(.reconnect).last == .open(attempt: 2, size: CellSize(cols: 80, rows: 24)))
        #expect(machine.reduce(.openFailed(attempt: 2)) == [.status(.disconnected(.attachFailed, reconnecting: false))])
        #expect(machine.reduce(.reconnect).last == .openAfterBackoff(attempt: 3, size: CellSize(cols: 80, rows: 24), failedReconnects: 1))
        _ = machine.reduce(.openFailed(attempt: 3))
        #expect(machine.reduce(.focused).last == .openAfterBackoff(attempt: 4, size: CellSize(cols: 80, rows: 24), failedReconnects: 2))
        // Reaching live resets the count: the next disconnect re-attaches at once.
        _ = machine.reduce(.opened(9, attempt: 4))
        _ = machine.reduce(.replayDelivered(9))
        _ = machine.reduce(.ended(9, .connectionLost("x")))
        #expect(machine.reduce(.reconnect).last == .open(attempt: 5, size: CellSize(cols: 80, rows: 24)))
    }

    @Test func nothingReattachesWithoutAnEvent() {
        var machine = disconnected()
        _ = machine.reduce(.visibility(false))
        #expect(machine.reduce(.resize(CellSize(cols: 90, rows: 30))) == [])
        #expect(machine.reduce(.gridAnnounced(7, CellSize(cols: 90, rows: 30))) == [])
        if case .disconnected = machine.phase {} else { Issue.record("left disconnected: \(machine.phase)") }
    }

    @Test func anExitedTerminalNeverReattaches() {
        var machine = disconnected()
        #expect(machine.reduce(.processExited) == [.status(.exited)])
        #expect(machine.reduce(.focused) == [])
        #expect(machine.reduce(.reconnect) == [])
        #expect(machine.reduce(.visibility(false)) == [])
        #expect(machine.reduce(.visibility(true)) == [])
        #expect(machine.reduce(.input(Data("x".utf8))) == [])
        #expect(machine.droppedInputBytes == 1)
        #expect(machine.reduce(.close) == [.finish])
    }

    @Test func aLiveViewWhoseProcessEndsDetachesAndShowsExited() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(7, attempt: 1))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.reduce(.processExited) == [.detach(7), .status(.exited)])
        #expect(machine.phase == .exited)
    }

    /// A tab that is already dead still shows its last screen.
    @Test func anExitDuringTheAttachWaitsForTheReplay() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        #expect(machine.reduce(.processExited) == [])
        _ = machine.reduce(.opened(7, attempt: 1))
        #expect(machine.reduce(.replayDelivered(7)) == [.detach(7), .status(.exited)])
        #expect(machine.phase == .exited)
    }

    /// R41: the daemon said the tab was dead (a tab briefly without a
    /// surface, a host being re-adopted), then that it lives. The view must
    /// re-attach; a live shell never stays "Process exited".
    @Test func anExitedViewReattachesWhenTheDaemonRevivesTheTerminal() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(7, attempt: 1))
        _ = machine.reduce(.replayDelivered(7))
        _ = machine.reduce(.processExited)
        let effects = machine.reduce(.processRevived)
        #expect(effects.contains(.status(.disconnected(.streamEnded, reconnecting: true))))
        guard case .open(let attempt, _)? = effects.first(where: { if case .open = $0 { true } else { false } }) else {
            Issue.record("revived view did not re-attach: \(effects)")
            return
        }
        _ = machine.reduce(.opened(8, attempt: attempt))
        #expect(machine.reduce(.replayDelivered(8)).contains(.status(.connected)))
        #expect(machine.liveLink == 8)
        #expect(machine.reduce(.input(Data("x".utf8))).contains(.send(8, Data("x".utf8))))
    }

    /// An exit reported while an attach was pending is withdrawn by a revive:
    /// the replay lands and the view goes live, not exited.
    @Test func aReviveDuringTheAttachCancelsThePendingExit() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        _ = machine.reduce(.processExited)
        _ = machine.reduce(.processRevived)
        _ = machine.reduce(.opened(7, attempt: 1))
        let effects = machine.reduce(.replayDelivered(7))
        #expect(!effects.contains(.status(.exited)))
        #expect(!effects.contains(.detach(7)))
        #expect(machine.liveLink == 7)
    }

    /// A revive is a daemon fact: it never re-attaches a live view.
    @Test func aReviveOfALiveViewDoesNothing() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        _ = machine.reduce(.start)
        _ = machine.reduce(.opened(7, attempt: 1))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.reduce(.processRevived) == [])
    }

    @Test func anExitWhileReattachingEndsExitedWhenTheAttachFails() {
        var machine = disconnected()
        _ = machine.reduce(.reconnect)
        _ = machine.reduce(.processExited)
        #expect(machine.reduce(.openFailed(attempt: 2)) == [.status(.exited)])
    }
}

/// The cursor restore never overrides the user's Ghostty cursor.
struct TerminalCursorDefaultTests {
    @Test func theUsersOwnShapeIsNotWritten() {
        let bar = TerminalCursorDefault(style: "bar", blink: false)
        #expect(bar.restore(style: "bar", blink: false).isEmpty)
        #expect(bar.restore(style: nil, blink: nil).isEmpty)
        #expect(bar.restore(style: "block", blink: true) == Data("\u{1B}[1 q".utf8))
        #expect(TerminalCursorDefault.ghostty.restore(style: "block", blink: nil).isEmpty)
        #expect(TerminalCursorDefault.ghostty.restore(style: "underline", blink: false) == Data("\u{1B}[4 q".utf8))
    }

    @Test func thePlanSkipsTheDefaultAndKeepsPendingLast() throws {
        let colors = try JSONDecoder().decode(TerminalColors.self, from: Data(#"{"cursor_style":"bar","cursor_blink":true}"#.utf8))
        let replay = TerminalReplay(cols: 80, rows: 24, data: Data("x".utf8), colors: colors, pending: Data("\u{1B}[1".utf8))
        let asDefault = TerminalCursorDefault(style: "bar", blink: nil)
        #expect(TerminalStreamPlan.steps(for: .replay(replay), cursorDefault: asDefault).last == .output(Data("\u{1B}[1".utf8)))
        #expect(TerminalStreamPlan.steps(for: .replay(replay)).last == .output(Data("\u{1B}[5 q\u{1B}[1".utf8)))
    }
}

/// The driver waits the backoff only before a re-attach that follows a
/// failed one, and a close during that wait opens nothing.
@Suite(.timeLimit(.minutes(1)))
struct TerminalReattachDriverTests {
    typealias Driver = TerminalAttachDriver<FakeLink>

    private nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _opens = 0
        private var _delays: [Int] = []
        private var _failNext = false
        private var _last: FakeLink?
        var opens: Int { lock.withLock { _opens } }
        var delays: [Int] { lock.withLock { _delays } }
        var last: FakeLink? { lock.withLock { _last } }
        func failNextOpen() { lock.withLock { _failNext = true } }
        /// Counts an open; nil when it must fail.
        func open() -> FakeLink? {
            lock.withLock {
                _opens += 1
                if _failNext { _failNext = false; return nil }
                let link = FakeLink(id: _opens)
                _last = link
                return link
            }
        }
        func delayed(_ n: Int) { lock.withLock { _delays.append(n) } }
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func backoffOnlyAfterAFailedReattachAndCloseCancelsIt() async {
        let recorder = Recorder()
        let gate = AsyncStream<Void>.makeStream()
        let driver = Driver(
            initialSize: CellSize(cols: 80, rows: 24),
            opener: { size in
                guard let link = recorder.open() else { throw CancellationError() }
                link.emit(.replay(TerminalReplay(cols: size.cols, rows: size.rows, data: Data("R".utf8))))
                return link
            },
            backoffDelay: { failed in
                recorder.delayed(failed)
                for await _ in gate.stream { return }
                throw CancellationError()
            })
        driver.start()
        await eventually("first attach live") { driver.machine.liveLink != nil }
        recorder.last?.emit(.closed(.surfaceGone))
        await eventually("disconnected") { if case .disconnected = driver.machine.phase { true } else { false } }

        recorder.failNextOpen()
        driver.focused()
        await eventually("failed re-attach") { recorder.opens == 2 && { if case .disconnected = driver.machine.phase { true } else { false } }() }
        #expect(recorder.delays.isEmpty, "the first re-attach must not wait")

        driver.focused()
        await eventually("backoff started") { recorder.delays == [1] }
        driver.focused()
        driver.input(Data("x".utf8))
        #expect(recorder.delays == [1], "one re-attach at a time")
        driver.close()
        gate.continuation.finish()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.opens == 2, "a close during the backoff must not open")
    }
}
