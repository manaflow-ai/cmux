import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import Testing

/// QUIT P0 speed (lead 2026-11-01 05:40Z): a quit-and-reopen bench reads, per visible terminal, when its pane showed
/// it and when its link to the daemon went live (`debug.timings` `launch_terminals`). The timeline joins a link that
/// went live before its pane showed it, keeps each first mark, and takes nothing after its launch window or past its
/// capacity; its attach observer marks only on the event that makes the link live.
@MainActor
struct TerminalLaunchTimelineTests {
    private nonisolated final class Clock: Sendable {
        let value = Mutex(Date(timeIntervalSince1970: 0))
        func set(_ ms: Double) { value.withLock { $0 = Date(timeIntervalSince1970: ms / 1_000) } }
        var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    }

    private nonisolated final class Log: Sendable {
        let events = Mutex<[String]>([])
    }

    private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1_000).rounded() }

    @Test func eachShownTerminalGetsItsLinkLiveMarkWhicheverCameFirst() {
        let clock = Clock()
        let timeline = TerminalLaunchTimeline(window: 60, capacity: 8, now: clock.now)
        clock.set(100)
        timeline.linkLive(surface: 7) // the link of tab_b went live before its pane showed it
        clock.set(120)
        _ = timeline.shown(key: "tab_a", surface: 5)
        clock.set(130)
        _ = timeline.shown(key: "tab_b", surface: 7)
        clock.set(150)
        timeline.linkLive(surface: 5)
        clock.set(400)
        timeline.linkLive(surface: 5) // a later re-attach does not move the first mark

        let report = timeline.report(Self.ms)
        #expect(report.map(\.key) == ["tab_a", "tab_b"])
        #expect(report.map(\.ms) == [["shown_ms": 120, "link_live_ms": 150], ["shown_ms": 130, "link_live_ms": 100]])
    }

    @Test func theObserverMarksOnlyTheEventThatMakesTheLinkLiveAndKeepsTheJournal() {
        let clock = Clock()
        let timeline = TerminalLaunchTimeline(window: 60, capacity: 8, now: clock.now)
        let journaled = Log()
        let observer = TerminalLaunchTimeline.observing(timeline, { @Sendable (event: String, _: Int) in journaled.events.withLock { $0.append(event) } },
                                                        surface: 3) { event, _ in event == "replay" }
        _ = timeline.shown(key: "tab_a", surface: 3)
        clock.set(50)
        observer?("input", 0)
        clock.set(80)
        observer?("replay", 0)

        #expect(journaled.events.withLock { $0 } == ["input", "replay"])
        #expect(timeline.report(Self.ms).map(\.ms) == [["shown_ms": 0, "link_live_ms": 80]])
    }

    @Test func nothingIsTakenAfterTheLaunchWindowOrPastCapacity() {
        let clock = Clock()
        let timeline = TerminalLaunchTimeline(window: 1, capacity: 2, now: clock.now)
        clock.set(10)
        _ = timeline.shown(key: "tab_a", surface: 1)
        #expect(!timeline.shown(key: "tab_remote", surface: 0)) // under capacity, but no daemon surface: nothing to time
        _ = timeline.shown(key: "tab_b", surface: 2)
        _ = timeline.shown(key: "tab_c", surface: 3) // past capacity
        clock.set(1_001)
        #expect(!timeline.isOpen)
        timeline.linkLive(surface: 1) // after the window

        #expect(timeline.report(Self.ms).map(\.key) == ["tab_a", "tab_b"])
        #expect(timeline.entries.allSatisfy { $0.linkLive == nil })
        let closed = TerminalLaunchTimeline.observing(timeline, nil as (@Sendable (String, Int) -> Void)?, surface: 1) { _, _ in true }
        #expect(closed == nil)
    }
}
