#if DEBUG || CMUX_BENCH_HOOKS
import Atomics
import Foundation
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// A WebKit page's presented stage: the bench script's report, as WebKit hands it to the handler, maps
/// the page's clock to uptime and closes the input's webkitPage slot with source pageEstimated; a report no slot takes
/// is counted and changes nothing.
@MainActor
@Suite(.serialized) struct WebPageInputTimingTests {
    typealias Harness = InputLatencyTrackerTests.Harness

    /// Uptime of the page's time 0 in these tests.
    private static let pageZero: UInt64 = 900_000_000
    /// The wall clock (epoch milliseconds) at uptime 0: the harness's wall clock runs with its uptime.
    private static let wallAtBoot = 1_761_550_000_000.0
    /// The page's `performance.timeOrigin`: the wall time of its time 0, the same whenever the page reads it.
    private static let origin = wallAtBoot + Double(pageZero) / 1e6

    private func begin(_ harness: Harness, kind: InputEventKind = .keyPress, target: InputTarget = .webkitPage,
                       ageNanos: UInt64 = 2_000_000) -> InputLatencyToken? {
        harness.tracker.begin(kind: kind, target: target, entrypoint: .person,
                              eventTimestamp: TimeInterval(harness.now - ageNanos) / 1e9, window: nil)
    }

    private func makeTiming(_ harness: Harness) -> WebPageInputTiming {
        let clock = harness.clock
        let wallAtBoot = Self.wallAtBoot
        return WebPageInputTiming(tracker: harness.tracker, now: { clock.load(ordering: .relaxed) },
                                  wallMillis: { wallAtBoot + Double(clock.load(ordering: .relaxed)) / 1e6 })
    }

    /// Page milliseconds of uptime `nanos`.
    private func pageMillis(_ nanos: UInt64) -> Double { Double(nanos - Self.pageZero) / 1e6 }

    /// A report as WebKit delivers the script's message: Foundation numbers in a dictionary and an array. It arrives
    /// when `receive` is called, at the harness's now; advance the harness first to model a slow delivery.
    private func recorded(_ events: [(WebPageInputTiming.EventType, UInt64, UInt64)]) -> Any {
        let flat = events.flatMap { [NSNumber(value: $0.0.rawValue), NSNumber(value: pageMillis($0.1)),
                                     NSNumber(value: pageMillis($0.2))] }
        return ["o": NSNumber(value: Self.origin), "e": flat as NSArray] as NSDictionary
    }

    @Test("A recorded report closes the waiting page slot at the page's paint, as pageEstimated")
    func recordedReportClosesTheSlot() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        let token = try #require(begin(harness))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        harness.tracker.endDispatch(token)
        harness.commit()
        #expect(harness.emitted.isEmpty && harness.tracker.waitingCount == 1, "a page's frame comes after the commit")

        let painted = harness.advance(6_000_000)
        timing.receive(recorded([(.keyDown, generated, painted)]))
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
        let token = try #require(begin(harness, kind: .mousePress))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        let painted = harness.advance(3_000_000)
        timing.receive(recorded([(.pointerDown, generated, painted)]))
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
        let first = try #require(begin(harness, ageNanos: 9_000_000))
        let second = try #require(begin(harness, ageNanos: 1_000_000))
        let firstEvent = try #require(harness.tracker.table.time(first, .generated))
        let secondEvent = try #require(harness.tracker.table.time(second, .generated))
        harness.commit()
        let painted = harness.advance(5_000_000)
        // The page clock is coarse: the second event's time is reported 1 ms late and still finds its own slot.
        timing.receive(recorded([(.keyDown, secondEvent + 1_000_000, painted)]))
        #expect(harness.emitted.map(\.generated) == [secondEvent])
        timing.receive(recorded([(.keyDown, firstEvent, painted)]))
        #expect(harness.emitted.map(\.generated) == [secondEvent, firstEvent])
        #expect(timing.matchedEvents == 2)
    }

    @Test("A report no page slot takes is counted and changes nothing; after the deadline it closes unpresented")
    func unmatchedReportsAreCounted() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        let page = try #require(begin(harness, ageNanos: 3_000_000))
        let agent = try #require(begin(harness, kind: .mousePress, target: .agentPane, ageNanos: 2_000_000))
        let pageEvent = try #require(harness.tracker.table.time(page, .generated))
        let agentEvent = try #require(harness.tracker.table.time(agent, .generated))
        harness.commit()
        let now = harness.advance(1_000_000)

        timing.receive(recorded([(.pointerDown, pageEvent, now)]))  // another kind
        timing.receive(recorded([(.pointerDown, agentEvent, now)]))  // not a WebKit page
        let far = pageEvent + WebPageInputTiming.matchToleranceNanos + 1
        timing.receive(recorded([(.keyDown, far, now)]))  // out of tolerance
        timing.receive(recorded([(.keyDown, pageEvent, pageEvent - 1)]))  // painted before it
        #expect(timing.unmatchedEvents == 4 && timing.matchedEvents == 0)
        #expect(harness.emitted.isEmpty && harness.tracker.waitingCount == 2, "both slots still wait")

        let late = harness.advance(InputLatencyTracker.contentDeadlineNanos)
        timing.receive(recorded([(.keyDown, pageEvent, late)]))
        #expect(timing.unmatchedEvents == 5)
        let slot = try #require(harness.emitted.first)
        #expect(slot.target == .webkitPage && !slot.reached(.presented), "past its deadline the slot is a no-echo slot")
        timing.receive(recorded([(.keyDown, pageEvent, late)]))
        #expect(timing.unmatchedEvents == 6, "its slot closed")
    }

    @Test("A body that is not the script's report is counted and read no further")
    func malformedBodiesAreCounted() throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        let token = try #require(begin(harness))
        let generated = try #require(harness.tracker.table.time(token, .generated))
        let bodies: [Any] = [
            "keydown",
            ["o": Self.origin] as NSDictionary,
            ["o": Self.origin, "e": [0, 1.0] as NSArray] as NSDictionary,
            ["o": Self.origin, "e": [7, 1.0, 2.0] as NSArray] as NSDictionary,
            ["o": Double.nan, "e": [] as NSArray] as NSDictionary,
            ["o": Double.infinity, "e": [0, pageMillis(generated), 1.0] as NSArray] as NSDictionary,
            ["o": Self.origin, "e": ["0", pageMillis(generated), 1.0] as NSArray] as NSDictionary,
        ]
        for body in bodies { timing.receive(body) }
        #expect(timing.malformedReports == UInt64(bodies.count))
        #expect(timing.matchedEvents == 0 && timing.unmatchedEvents == 0)
        #expect(harness.tracker.pendingCount == 1, "the slot is untouched")
    }

    @Test("A first report delivered late (busy main thread) still closes its own slot at the true paint",
          arguments: [UInt64(30_000_000), 80_000_000])
    func lateFirstReportKeepsTheTruePaint(delay: UInt64) throws {
        let harness = Harness()
        let timing = makeTiming(harness)
        // Key repeat: two key downs 30 ms apart, both waiting for the page's frame.
        let first = try #require(begin(harness, ageNanos: 31_000_000))
        let second = try #require(begin(harness, ageNanos: 1_000_000))
        let firstEvent = try #require(harness.tracker.table.time(first, .generated))
        let secondEvent = try #require(harness.tracker.table.time(second, .generated))
        harness.commit()
        #expect(harness.tracker.waitingCount == 2)
        let painted = harness.advance(4_000_000)

        harness.advance(delay)  // the page's first report waits this long for the app's main thread
        timing.receive(recorded([(.keyDown, firstEvent, painted)]))
        let slot = try #require(harness.emitted.first)
        #expect(slot.generated == firstEvent, "the delay does not move the event onto the next key's slot")
        #expect(slot.presented == painted && slot.presentationSource == .pageEstimated)
        #expect(timing.matchedEvents == 1 && timing.unmatchedEvents == 0)

        harness.advance(1_000_000)  // the next report comes promptly; the late one left nothing behind
        timing.receive(recorded([(.keyDown, secondEvent, painted)]))
        #expect(harness.emitted.map(\.generated) == [firstEvent, secondEvent])
        #expect(harness.emitted.last?.presented == painted && timing.matchedEvents == 2)
    }

    @Test("The page clock maps through the wall clock: the delivery delay cancels")
    func pageClockCancelsTheDeliveryDelay() throws {
        // The page's time 0 is wall 1_000 ms; the page posts at its 10 ms (wall 1_010, uptime 5_010 ms).
        for delay: UInt64 in [0, 3, 80, 400] {
            let arrival: UInt64 = 5_010_000_000 + delay * 1_000_000
            let clock = try #require(WebPageClock(originMillis: 1_000, wallMillis: 1_010 + Double(delay),
                                                  uptimeNanos: arrival))
            #expect(clock.uptime(10) == 5_010_000_000, "delivered \(delay) ms late, page time still maps to its uptime")
            #expect(clock.uptime(4) == 5_004_000_000)
        }
        let clock = try #require(WebPageClock(originMillis: 1_000, wallMillis: 1_010, uptimeNanos: 5_010_000_000))
        #expect(clock.uptime(-5_000) == nil && clock.uptime(.infinity) == nil && clock.uptime(.nan) == nil)
        #expect(WebPageClock(originMillis: .nan, wallMillis: 1_010, uptimeNanos: 1) == nil)
        #expect(WebPageClock(originMillis: -1e300, wallMillis: 1_010, uptimeNanos: 1) == nil)
        #expect(WebPageClock(originMillis: 1_000, wallMillis: 1_010, uptimeNanos: .max) == nil)
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
