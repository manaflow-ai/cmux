import AppKit
@testable import CmuxNextInput
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// The cost of one event through the app's input tap (perf-hot path id `input-tap`, 5 us): the dispatch scope,
/// the observers, the intercepts, the after-dispatch observers and the dispatch end, as
/// `CmuxApplication.sendEvent` runs them, with eight live subscribers (two window-scoped, one with a
/// `while` gate) and a key, a button, a move and a drag in a window. It prints the per-event
/// nanoseconds of each batch of `batch` events as p50, p95, p99 and max over `batches` batches. A
/// measurement, not a gate: run it in a Release build on each macOS major and quote the line. With
/// CMUX_PERF_RESULT_DIR it also writes the batches as result-v1 (lab story swift-input-tap).
///
/// ```
/// CMUX_INPUT_TAP_BENCH=1 swift test -c release --filter InputEventTapBench
/// ```
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_INPUT_TAP_BENCH"] == "1"))
struct InputEventTapBench {
    private static let batch = 1_000
    private static let batches = 2_000

    final class Count {
        var value = 0
    }

    @Test func nanosecondsPerEvent() throws {
        _ = NSApplication.shared
        let mine = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        mine.isReleasedWhenClosed = false
        mine.orderFrontRegardless()
        defer { mine.orderOut(nil) }
        let tap = InputEventTap()
        let count = Count()
        let subscriptions = [
            tap.subscribe(class: .all) { _ in count.value += 1 },
            tap.observe(.all, windowNumber: nil) { _ in count.value += 1 },
            tap.subscribe(class: .all, phase: .intercept(order: .standard), while: { count.value >= 0 }) { _ in
                count.value += 1
                return .pass
            },
            tap.subscribe(class: .all, phase: .afterDispatch) { _ in count.value += 1 },
            tap.subscribe(class: .all, window: .window(mine)) { _ in count.value += 1 },
            tap.observe(.all, windowNumber: mine.windowNumber + 1) { _ in count.value += 1 },
            tap.subscribe(class: .all, phase: .afterDispatch, window: .window(mine)) { _ in count.value += 1 },
            tap.observeDispatchEnd(.all) { _, _ in count.value += 1 },
        ]
        let events = [
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                          windowNumber: mine.windowNumber, context: nil, characters: "a",
                                          charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)),
            try Self.mouse(.leftMouseDown, in: mine),
            try Self.mouse(.mouseMoved, in: mine),
            try Self.mouse(.leftMouseDragged, in: mine),
        ]
        for event in events { Self.dispatch(event, through: tap) }  // warm: the per-class arrays and window keys

        var perEvent: [Double] = []
        perEvent.reserveCapacity(Self.batches)
        for index in 0..<Self.batches {
            let event = events[index % events.count]
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<Self.batch { Self.dispatch(event, through: tap) }
            perEvent.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(Self.batch))
        }
        try PerfResultWriter()?.record("swift.input_tap.event_ns", unit: .ns, samples: perEvent)
        perEvent.sort()
        func quantile(_ q: Double) -> Double { perEvent[min(perEvent.count - 1, Int(Double(perEvent.count) * q))] }
        print(String(format: "input-tap bench: macOS %@, %d batches of %d events, 8 subscribers: ns per event p50 %.0f p95 %.0f p99 %.0f max %.0f",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.batches, Self.batch,
                     quantile(0.5), quantile(0.95), quantile(0.99), perEvent[perEvent.count - 1]))
        #expect(count.value > Self.batches * Self.batch, "the subscribers heard the events")
        withExtendedLifetime(subscriptions) {}
    }

    /// One event's dispatch as `CmuxApplication.sendEvent` runs it: the three stages in one dispatch
    /// scope, then the dispatch end.
    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        var consumed = false
        tap.dispatching {
            tap.deliverObserve(event)
            consumed = tap.deliverIntercepts(event) == .consume
            tap.deliverAfterDispatch(event)
        }
        tap.deliverDispatchEnd(event, outcome: consumed ? .consumed : .delivered)
    }

    private static func mouse(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }
}
