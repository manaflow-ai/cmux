#if DEBUG || CMUX_BENCH_HOOKS
import Atomics
import Foundation
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// A WebKit page's presented stage (p04-input-099): the bench script's report, as WebKit hands it to the handler, maps
/// the page's clock to uptime and closes the input's webkitPage slot with source pageEstimated; a report no slot takes
/// is counted and changes nothing.
@MainActor
@Suite(.serialized) struct WebPageInputTimingTests {
    typealias Harness = InputLatencyTrackerTests.Harness

    /// Uptime of the page's time 0 in these tests.
    private static let pageZero: UInt64 = 900_000_000
    /// The page's `performance.timeOrigin` (epoch milliseconds; only its identity matters).
    private static let origin = 1_761_550_000_123.5

    private func begin(_ harness: Harness, kind: InputEventKind = .keyPress, target: InputTarget = .webkitPage,
                       ageNanos: UInt64 = 2_000_000) -> InputLatencyToken? {
        harness.tracker.begin(kind: kind, target: target, entrypoint: .person,
                              eventTimestamp: TimeInterval(harness.now - ageNanos) / 1e9, window: nil)
    }

    private func makeTiming(_ harness: Harness) -> WebPageInputTiming {
        let clock = harness.clock
        return WebPageInputTiming(tracker: harness.tracker, now: { clock.load(ordering: .relaxed) })
    }

    /// Page milliseconds of uptime `nanos`.
    private func pageMillis(_ nanos: UInt64) -> Double { Double(nanos - Self.pageZero) / 1e6 }

    /// A report as WebKit delivers the script's message: Foundation numbers in a dictionary and an array, posted at
    /// the harness's now (no delivery delay), so the page clock maps exactly.
    private func recorded(_ harness: Harness, _ events: [(WebPageInputTiming.EventType, UInt64, UInt64)]) -> Any {
        let flat = events.flatMap { [NSNumber(value: $0.0.rawValue), NSNumber(value: pageMillis($0.1)),
                                     NSNumber(value: pageMillis($0.2))] }
        return ["o": NSNumber(value: Self.origin), "n": NSNumber(value: pageMillis(harness.now)), "e": flat as NSArray]
            as NSDictionary
    }

    @Test("A recorded report closes the waiting page slot at the page's paint, as pageEstimated")
    func recordedReportClosesTheSlot() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        var clock = WebPageClock()
        let token = try #require(begin(harness))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        harness.tracker.endDispatch(token)
        harness.commit()
        #expect(harness.emitted.isEmpty && harness.tracker.waitingCount == 1, "a page's frame comes after the commit")

        let painted = harness.advance(6_000_000)
        timing.receive(recorded(harness, [(.keyDown, generated, painted)]), clock: &clock)
        let slot = try #require(harness.emitted.first)
        #expect(slot.target == .webkitPage && slot.kind == .keyPress)
        #expect(slot.presentationSource == .pageEstimated && slot.presented == painted)
        #expect(slot.nanos(from: .generated, to: .presented) == painted - generated)
        #expect(harness.presentation.asked.isEmpty, "the page's time needs no commit estimate")
        #expect(timing.matchedEvents == 1 && timing.unmatchedEvents == 0 && timing.malformedReports == 0)
        #expect(harness.tracker.waitingCount == 0)
    }

    @Test("A report for a page slot still in its turn closes it at the turn's commit")
    func reportInTheTurnClosesAtTheCommit() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        var clock = WebPageClock()
        let token = try #require(begin(harness, kind: .mousePress))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        let painted = harness.advance(3_000_000)
        timing.receive(recorded(harness, [(.pointerDown, generated, painted)]), clock: &clock)
        #expect(harness.emitted.isEmpty, "the slot closes with its turn")
        harness.tracker.endDispatch(token)
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.presented == painted && slot.presentationSource == .pageEstimated && slot.reached(.mainCommit))
        #expect(harness.tracker.waitingCount == 0 && harness.tracker.pendingCount == 0)
    }

    @Test("Two fast keys: each report closes the slot whose event time is nearest its own")
    func nearestSlotTakesTheReport() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        var clock = WebPageClock()
        let first = try #require(begin(harness, ageNanos: 9_000_000))
        let second = try #require(begin(harness, ageNanos: 1_000_000))
        let firstEvent = try #require(harness.tracker.table.time(first, .generated))
        let secondEvent = try #require(harness.tracker.table.time(second, .generated))
        harness.commit()
        let painted = harness.advance(5_000_000)
        // The page clock is coarse: the second event's time is reported 1 ms late and still finds its own slot.
        timing.receive(recorded(harness, [(.keyDown, secondEvent + 1_000_000, painted)]), clock: &clock)
        #expect(harness.emitted.map(\.generated) == [secondEvent])
        timing.receive(recorded(harness, [(.keyDown, firstEvent, painted)]), clock: &clock)
        #expect(harness.emitted.map(\.generated) == [secondEvent, firstEvent])
        #expect(timing.matchedEvents == 2)
    }

    @Test("A report no page slot takes is counted and changes nothing; after the deadline it closes unpresented")
    func unmatchedReportsAreCounted() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        var clock = WebPageClock()
        let page = try #require(begin(harness, ageNanos: 3_000_000))
        let agent = try #require(begin(harness, kind: .mousePress, target: .agentPane, ageNanos: 2_000_000))
        let pageEvent = try #require(harness.tracker.table.time(page, .generated))
        let agentEvent = try #require(harness.tracker.table.time(agent, .generated))
        harness.commit()
        let now = harness.advance(1_000_000)

        timing.receive(recorded(harness, [(.pointerDown, pageEvent, now)]), clock: &clock)  // another kind
        timing.receive(recorded(harness, [(.pointerDown, agentEvent, now)]), clock: &clock)  // not a WebKit page
        let far = pageEvent + WebPageInputTiming.matchToleranceNanos + 1
        timing.receive(recorded(harness, [(.keyDown, far, now)]), clock: &clock)  // out of tolerance
        timing.receive(recorded(harness, [(.keyDown, pageEvent, pageEvent - 1)]), clock: &clock)  // painted before it
        #expect(timing.unmatchedEvents == 4 && timing.matchedEvents == 0)
        #expect(harness.emitted.isEmpty && harness.tracker.waitingCount == 2, "both slots still wait")

        let late = harness.advance(InputLatencyTracker.contentDeadlineNanos)
        timing.receive(recorded(harness, [(.keyDown, pageEvent, late)]), clock: &clock)
        #expect(timing.unmatchedEvents == 5)
        let slot = try #require(harness.emitted.first)
        #expect(slot.target == .webkitPage && !slot.reached(.presented), "past its deadline the slot is a no-echo slot")
        timing.receive(recorded(harness, [(.keyDown, pageEvent, late)]), clock: &clock)
        #expect(timing.unmatchedEvents == 6, "its slot closed")
    }

    @Test("A body that is not the script's report is counted and read no further")
    func malformedBodiesAreCounted() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        var clock = WebPageClock()
        let token = try #require(begin(harness))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        let bodies: [Any] = [
            "keydown",
            ["o": Self.origin, "n": 1.0] as NSDictionary,
            ["o": Self.origin, "n": 1.0, "e": [0, 1.0] as NSArray] as NSDictionary,
            ["o": Self.origin, "n": 1.0, "e": [7, 1.0, 2.0] as NSArray] as NSDictionary,
            ["o": Self.origin, "n": Double.nan, "e": [] as NSArray] as NSDictionary,
            ["o": Self.origin, "n": 1.0, "e": ["0", pageMillis(generated), 1.0] as NSArray] as NSDictionary,
        ]
        for body in bodies { timing.receive(body, clock: &clock) }
        #expect(timing.malformedReports == UInt64(bodies.count))
        #expect(timing.matchedEvents == 0 && timing.unmatchedEvents == 0)
        #expect(clock == WebPageClock(), "a malformed report does not move the page clock")
    }

    @Test("The page clock keeps the smallest delivery offset and starts over for a new document")
    func pageClockKeepsTheBestOffset() {
        var clock = WebPageClock()
        #expect(clock.uptime(1) == nil, "no report yet")
        clock.observe(origin: Self.origin, pageNowMillis: 10, receivedAt: 1_013_000_000)  // 3 ms in delivery
        #expect(clock.uptime(10) == 1_013_000_000)
        clock.observe(origin: Self.origin, pageNowMillis: 20, receivedAt: 1_021_000_000)  // 1 ms: better
        #expect(clock.uptime(10) == 1_011_000_000)
        clock.observe(origin: Self.origin, pageNowMillis: 30, receivedAt: 1_035_000_000)  // 5 ms: kept the 1 ms
        #expect(clock.uptime(10) == 1_011_000_000)
        clock.observe(origin: Self.origin + 1, pageNowMillis: 1, receivedAt: 2_000_000_000)  // a new document
        #expect(clock.uptime(1) == 2_000_000_000)
        #expect(clock.uptime(-5_000) == nil && clock.uptime(.infinity) == nil)
    }

    @Test("The script listens only for trusted inputs, passively, and posts numbers to its own channel")
    func scriptShape() {
        let script = WebPageInputTiming.script
        #expect(script.contains("window.webkit.messageHandlers.\(WebPageInputTiming.channel)"))
        for type in WebPageInputTiming.EventType.allCases { #expect(script.contains("\(type.domType): \(type.rawValue)")) }
        #expect(script.contains("event.isTrusted") && script.contains("passive: true"))
        #expect(script.contains("requestAnimationFrame"))
    }
}
#endif
