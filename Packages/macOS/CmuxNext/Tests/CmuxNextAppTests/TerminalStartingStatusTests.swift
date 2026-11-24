import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFocusUI
@testable import CmuxNextTerminal
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A new pane whose split the daemon had not confirmed said nothing: its view attaches only after
/// the daemon's tab replaces the stand-in, and until then its link said `connected`, so a session
/// that did not answer left an empty pane with no word and no way out but Close Tab.
///
/// The view of a terminal the daemon has not confirmed now says `starting` from its first turn
/// until its first replay.
struct TerminalStartingAttachTests {
    typealias Machine = TerminalAttachMachine<Int>

    /// The attempt the effects open.
    private func opened(_ effects: [Machine.Effect]) -> Int? {
        for effect in effects {
            switch effect {
            case .open(let attempt, _): return attempt
            case .openAfterBackoff(let attempt, _, _): return attempt
            default: continue
            }
        }
        return nil
    }

    /// The open of a creating view waits for the daemon's tab and does not return: the view says
    /// `starting` at once, through the keys typed meanwhile, and until its first replay.
    @Test func aCreatingViewWhoseOpenNeverReturnsSaysStarting() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: false, creating: true)
        let attempt = try #require(opened(machine.reduce(.start)))
        #expect(machine.status == .starting, "a creating view says \(machine.status) while its open waits")
        _ = machine.reduce(.input(Data("ls\r".utf8)))
        #expect(machine.status == .starting, "keys typed while it starts changed its status to \(machine.status)")
        // The daemon confirms: the open returns, and the first replay makes it live.
        _ = machine.reduce(.opened(7, attempt: attempt))
        #expect(machine.status == .starting, "an open with no replay yet says \(machine.status)")
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.status == .connected)
    }

    /// A failed attach of a creating view is retried under the same word, and nothing is rolled
    /// back; a daemon that never takes it ends as any view's does, with Retry.
    @Test func aCreatingViewWhoseAttachFailsStillSaysStarting() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: false, creating: true)
        var attempt = try #require(opened(machine.reduce(.start)))
        for failure in 1...5 {
            attempt = try #require(opened(machine.reduce(.openFailed(attempt: attempt))))
            #expect(machine.status == .starting, "failure \(failure): \(machine.status)")
        }
        for _ in 1...60 { attempt = try #require(opened(machine.reduce(.openFailed(attempt: attempt)))) }
        #expect(machine.status == .disconnected(.attachFailed, reconnecting: false))
    }

    /// Only a creating view says it: a view of a terminal that runs says nothing, or `restoring`.
    @Test func aViewOfARunningTerminalNeverSaysStarting() {
        var plain = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true)
        _ = plain.reduce(.start)
        #expect(plain.status == .connected)
        var restored = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        _ = restored.reduce(.start)
        #expect(restored.status == .restoring)
    }
}

/// The label of a pane that still starts: nothing for the first second (the daemon confirms a split
/// well within it), then the in-between mark, and 10 s after the start the words that say the
/// session is not answering, with Close. The times run on an injected clock.
@MainActor @Suite struct TerminalStartingLabelTests {
    private static func banner(in host: TerminalHostView) -> TerminalStatusBanner? {
        TerminalStatusBannerLazyTests.banners(in: host).first
    }

    /// Whether the label comes to show `text` (nil: nothing) within some turns of the main actor.
    private static func shows(_ text: String?, in host: TerminalHostView) async -> Bool {
        var turns = 0
        while host.statusText != text, turns < 10_000 { await Task.yield(); turns += 1 }
        return host.statusText == text
    }

    private static func turns(_ count: Int = 200) async {
        for _ in 0..<count { await Task.yield() }
    }

    @Test func theMarkShowsAfterOneSecondAndTheWordsWithCloseAfterTen() async throws {
        #expect(TerminalStatusBanner.revealDelay(for: .starting, stall: nil) == 1)
        #expect(TerminalStatusBanner.overdueDelay(for: .starting, stall: nil) == 10)
        let starting = try #require(TerminalStatusBanner.text(for: .starting), "a starting pane has no words")
        let overdue = try #require(TerminalStatusBanner.overdueText(for: .starting), "a pane that still starts has no later words")
        #expect(overdue != starting)

        let clock = ManualClock()
        let host = TerminalHostView(clock: clock)
        var closes = 0
        host.onCloseStarting = { closes += 1 }
        host.showStatus(.starting)
        #expect(host.statusText == nil, "the label shows before its second")
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(900))
        await Self.turns()
        #expect(host.statusText == nil, "the label shows 0.9 s after the start")
        #expect(clock.sleeperCount == 1)

        // 1 s: the mark, with the words as its accessibility label and no Close.
        clock.advance(by: .milliseconds(100))
        let shown1 = await Self.shows(starting, in: host)
        #expect(shown1, "1 s after the start the label shows \(host.statusText ?? "nothing")")
        #expect(Self.banner(in: host)?.showsMark == true, "the label of the first seconds is the in-between mark")
        #expect(host.startingCloseTitle == nil, "Close shows before the words")
        #expect(!host.pressStartingClose())

        // The words come 10 s after the START of the status (9 s after the mark), not after the mark.
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines.map { clock.now.duration(to: $0) } == [.seconds(9)])
        clock.advance(by: .milliseconds(8_900))
        await Self.turns()
        #expect(host.statusText == starting, "9.9 s after the start the label shows \(host.statusText ?? "nothing")")
        clock.advance(by: .milliseconds(100))
        let shown2 = await Self.shows(overdue, in: host)
        #expect(shown2, "10 s after the start the label shows \(host.statusText ?? "nothing")")
        #expect(Self.banner(in: host)?.showsMark == false, "the later words show as words")
        #expect(host.startingCloseTitle == TerminalStatusBanner.closeTitle(), "the later words offer no Close")
        #expect(host.startingCloseTitle?.isEmpty == false)

        // Close calls the pane's close once for each press. Nothing was rolled back at 10 s: the
        // pane still starts, and its first replay takes the label away with its Close.
        #expect(host.pressStartingClose())
        #expect(closes == 1)
        host.showStatus(.starting)
        #expect(host.statusText == overdue, "the same status again changed the words")
        host.showStatus(.connected)
        #expect(host.statusText == nil)
        #expect(host.startingCloseTitle == nil)
        #expect(!host.pressStartingClose())
        #expect(closes == 1)
    }

    /// The usual split: the daemon confirms within the second, so no label is built and no timer
    /// of the later words stays.
    @Test func aPaneThatStartsWithinASecondShowsNothing() async throws {
        let clock = ManualClock()
        let host = TerminalHostView(clock: clock)
        host.onCloseStarting = {}
        host.showStatus(.starting)
        host.showStatus(.connected)
        clock.advance(by: .seconds(20))
        await Self.turns()
        #expect(host.statusText == nil)
        #expect(TerminalStatusBannerLazyTests.banners(in: host).isEmpty, "a start that clears within its second builds no label")
        #expect(clock.sleeperCount == 0, "a timer of the cleared status still waits")
    }

    /// A status that comes after the 10 s deadline, before the woken task ran, says the later
    /// words then; the deadline does not start again.
    @Test func aStatusAfterTheDeadlineSaysTheLaterWordsAtOnce() async throws {
        let starting = try #require(TerminalStatusBanner.text(for: .starting), "a starting pane has no words")
        let overdue = try #require(TerminalStatusBanner.overdueText(for: .starting), "a pane that still starts has no later words")
        let clock = ManualClock()
        let host = TerminalHostView(clock: clock)
        host.onCloseStarting = {}
        host.showStatus(.starting)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        let shown3 = await Self.shows(starting, in: host)
        #expect(shown3)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(9))
        // No suspension since the advance: the woken task has not run on the main actor yet.
        host.showStatus(.starting)
        #expect(host.statusText == overdue, "the deadline passed: the label says \(host.statusText ?? "nothing")")
        #expect(host.startingCloseTitle == TerminalStatusBanner.closeTitle())
        // Another status takes the label: its own words, and no Close.
        host.showStatus(.exited)
        #expect(host.statusText == TerminalStatusBanner.text(for: .exited))
        #expect(host.startingCloseTitle == nil, "Close stays under another status")
    }

    /// A host with no close action (a view outside a tab) says the later words with no button.
    @Test func withNoCloseActionTheLaterWordsHaveNoClose() async throws {
        let overdue = try #require(TerminalStatusBanner.overdueText(for: .starting), "a pane that still starts has no later words")
        let clock = ManualClock()
        let host = TerminalHostView(clock: clock)
        host.showStatus(.starting)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        let shown4 = await Self.shows(TerminalStatusBanner.text(for: .starting), in: host)
        #expect(shown4)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(9))
        let shown5 = await Self.shows(overdue, in: host)
        #expect(shown5)
        #expect(host.startingCloseTitle == nil)
        #expect(!host.pressStartingClose())
    }
}

/// Keys typed in a pane that still starts go to the daemon, which gives them back when no terminal
/// took them (10 s after the first). They were then typed into the focused terminal of the window.
/// After the person closed that pane, the focused terminal is its neighbour: the keys ran there.
/// Keys of a creation the person closed are dropped, held already or given back later.
@MainActor @Suite struct StartingCloseKeysTests {
    @Test func keysOfAClosedStartingPaneReachNoOtherTerminal() {
        let input = GivenBackInput(limit: .seconds(60))
        var typed = Data()
        // Given back while the starting pane has the focus (no terminal can take them), then Close.
        input.deliver(adding: Data("rm -r build\r".utf8), from: "starting", window: "A", to: nil)
        input.creationClosed(terminal: "starting")
        input.deliver(window: "A", to: { typed.append($0) })
        #expect(typed.isEmpty, "keys typed in the closed pane were typed into its neighbour: \(String(decoding: typed, as: UTF8.self))")
        // Given back after the close.
        input.deliver(adding: Data("y\r".utf8), from: "starting", window: "A", to: { typed.append($0) })
        input.deliver(window: "A", to: { typed.append($0) })
        #expect(typed.isEmpty, "keys given back after the close were typed into another terminal: \(String(decoding: typed, as: UTF8.self))")
    }

    /// Only the closed creation's keys are dropped: those of a creation that failed by itself, and
    /// keys with no named terminal, still go to the focused terminal of their window, in order.
    @Test func keysOfOtherCreationsStillGoToTheirWindow() {
        let input = GivenBackInput(limit: .seconds(60))
        var typed = Data()
        input.deliver(adding: Data("a".utf8), from: "failed", window: "A", to: nil)
        input.deliver(adding: Data("b".utf8), from: "starting", window: "A", to: nil)
        input.deliver(adding: Data("c".utf8), window: "A", to: nil)
        input.creationClosed(terminal: "starting")
        input.deliver(window: "A", to: { typed.append($0) })
        #expect(typed == Data("ac".utf8), "got \(String(decoding: typed, as: UTF8.self))")
    }
}
