@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// A locked or display-asleep Mac streams black with healthy-looking stats
/// (Leo's NIGHTLY, 2026-11-17): the host follows lock and display sleep and
/// tells the viewer, and the notice clears the moment the Mac unlocks or wakes.
struct ScreenSourceStateTests {
    /// Events a test sends by hand, from a state it sets.
    final class FakeEvents: ScreenSourceEvents, @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (ScreenSourceTracker.Event) -> Void)?
        private(set) var cancelled = false
        let initial: ScreenSourceTracker

        init(_ initial: ScreenSourceTracker = ScreenSourceTracker()) { self.initial = initial }

        func current() -> ScreenSourceTracker { initial }

        func observe(_ event: @escaping @Sendable (ScreenSourceTracker.Event) -> Void) -> @Sendable () -> Void {
            lock.withLock { sink = event }
            return { [weak self] in
                guard let self else { return }
                lock.withLock {
                    sink = nil
                    cancelled = true
                }
            }
        }

        func send(_ event: ScreenSourceTracker.Event) { lock.withLock { sink }?(event) }
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ScreenSourceState] = []
        func append(_ state: ScreenSourceState) { lock.withLock { states.append(state) } }
        var all: [ScreenSourceState] { lock.withLock { states } }
    }

    @Test func lockedWinsOverAsleepAndEachEventChangesOnlyItsOwnPart() {
        var tracker = ScreenSourceTracker()
        #expect(tracker.state == .live)
        #expect(tracker.apply(.locked) == .locked)
        #expect(tracker.apply(.displaySlept) == nil) // still locked
        #expect(tracker.apply(.locked) == nil)
        #expect(tracker.apply(.unlocked) == .asleep)
        #expect(tracker.apply(.displayWoke) == .live)
        #expect(tracker.apply(.displayWoke) == nil)
    }

    @Test func theMonitorReportsTheStateNowThenEachChangeUntilStopped() {
        let events = FakeEvents(), reports = Reports()
        let monitor = ScreenSourceMonitor(events: events) { reports.append($0) }
        monitor.start()
        #expect(reports.all == [.live])
        events.send(.locked)
        #expect(reports.all == [.live, .locked])
        events.send(.unlocked)
        #expect(reports.all == [.live, .locked, .live])
        events.send(.displaySlept)
        events.send(.displayWoke)
        #expect(reports.all == [.live, .locked, .live, .asleep, .live])
        monitor.stop()
        #expect(events.cancelled)
        events.send(.locked)
        #expect(reports.all.count == 5)
    }

    @Test func aViewerThatConnectsToALockedMacHearsLockedAtOnce() {
        let events = FakeEvents(ScreenSourceTracker(locked: true, asleep: true)), reports = Reports()
        let monitor = ScreenSourceMonitor(events: events) { reports.append($0) }
        monitor.start()
        #expect(reports.all == [.locked])
        events.send(.displayWoke)
        events.send(.unlocked)
        #expect(reports.all == [.locked, .live])
    }

    @Test func aMonitorStoppedBeforeItStartsNeverReports() {
        let events = FakeEvents(), reports = Reports()
        let monitor = ScreenSourceMonitor(events: events) { reports.append($0) }
        monitor.stop()
        monitor.start()
        #expect(reports.all.isEmpty)
        #expect(events.cancelled)
    }

    @Test func theSourceMessageRoundTripsAndOtherMessagesCarryNone() throws {
        let data = try JSONEncoder().encode(ScreenHostMessage(source: .locked))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["t"] as? String == "source")
        #expect(object["s"] as? String == "locked")
        let decoded = try JSONDecoder().decode(ScreenHostMessage.self, from: data)
        #expect(decoded.sourceState == .locked)
        for state in ScreenSourceState.allCases {
            #expect(try JSONDecoder().decode(ScreenHostMessage.self, from: JSONEncoder().encode(ScreenHostMessage(source: state))).sourceState == state)
        }
        // A displays message is not a source message, nor a value this viewer does not know.
        #expect(ScreenHostMessage(t: "displays", s: "locked").sourceState == nil)
        #expect(ScreenHostMessage(t: ScreenHostMessage.sourceType, s: "dreaming").sourceState == nil)
        #expect(!ScreenStreamViewer.isDisplays(decoded))
        #expect(ScreenStreamViewer.capabilities(in: decoded) == nil)
    }

    #if os(macOS)
    @Test func theCaptureBackendFollowsItsEventsUntilItStops() {
        let events = FakeEvents(), reports = Reports()
        let backend = ScreenCaptureBackend(log: { _ in }, timing: nil, input: EventInjector(source: nil) { _ in },
                                           writePasteboard: { _, _ in false }, sourceEvents: events)
        backend.observeSourceState { reports.append($0) }
        events.send(.locked)
        events.send(.unlocked)
        #expect(reports.all == [.live, .locked, .live])
        backend.stop()
        #expect(events.cancelled)
        events.send(.locked)
        #expect(reports.all.count == 3)
        // After stop no new monitor starts.
        backend.observeSourceState { reports.append($0) }
        #expect(reports.all.count == 3)
    }
    #endif
}
