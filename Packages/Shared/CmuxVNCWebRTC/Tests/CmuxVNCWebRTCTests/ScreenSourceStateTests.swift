@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// A locked or display-asleep Mac streams black with healthy-looking stats
/// (Leo's NIGHTLY, 2026-11-17): the host reads lock and display sleep and
/// tells the viewer, and the notice clears the moment the Mac unlocks or wakes.
struct ScreenSourceStateTests {
    /// A Mac's lock and display sleep that a test sets by hand.
    final class FakeProbe: ScreenSourceProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var locked: Bool
        private var asleep: Bool
        private(set) var reads = 0

        init(locked: Bool = false, asleep: Bool = false) {
            self.locked = locked
            self.asleep = asleep
        }

        func set(locked: Bool? = nil, asleep: Bool? = nil) {
            lock.withLock {
                if let locked { self.locked = locked }
                if let asleep { self.asleep = asleep }
            }
        }

        func read() -> ScreenSourceState {
            lock.withLock {
                reads += 1
                return ScreenSourceState(locked: locked, asleep: asleep)
            }
        }
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ScreenSourceState] = []
        func append(_ state: ScreenSourceState) { lock.withLock { states.append(state) } }
        var all: [ScreenSourceState] { lock.withLock { states } }
    }

    @Test func lockedWinsOverAsleep() {
        #expect(ScreenSourceState(locked: false, asleep: false) == .live)
        #expect(ScreenSourceState(locked: true, asleep: false) == .locked)
        #expect(ScreenSourceState(locked: true, asleep: true) == .locked)
        #expect(ScreenSourceState(locked: false, asleep: true) == .asleep)
    }

    /// Lock → locked sent → unlock → live, and nothing in between repeats.
    @Test func theMonitorReportsTheFirstReadingThenOnlyChangesUntilStopped() {
        let probe = FakeProbe(), reports = Reports()
        let monitor = ScreenSourceMonitor(probe: probe) { reports.append($0) }
        #expect(monitor.state == nil)
        monitor.check()
        #expect(reports.all == [.live])
        monitor.check()
        #expect(reports.all == [.live], "an unchanged reading says nothing")
        probe.set(locked: true)
        monitor.check()
        #expect(reports.all == [.live, .locked])
        probe.set(asleep: true)
        monitor.check()
        #expect(reports.all == [.live, .locked], "a locked Mac's display sleeping is still locked")
        probe.set(locked: false)
        monitor.check()
        probe.set(asleep: false)
        monitor.check()
        #expect(reports.all == [.live, .locked, .asleep, .live])
        monitor.stop()
        probe.set(locked: true)
        monitor.check()
        #expect(reports.all.count == 4)
    }

    @Test func aViewerThatConnectsToALockedMacHearsLockedAtOnce() {
        let probe = FakeProbe(locked: true, asleep: true), reports = Reports()
        let monitor = ScreenSourceMonitor(probe: probe) { reports.append($0) }
        monitor.check()
        #expect(reports.all == [.locked])
        probe.set(locked: false, asleep: false)
        monitor.check()
        #expect(reports.all == [.locked, .live])
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
    @Test func theCaptureBackendReportsItsProbeUntilItStops() {
        let probe = FakeProbe(), reports = Reports()
        let backend = ScreenCaptureBackend(log: { _ in }, timing: nil, input: EventInjector(source: nil) { _ in },
                                           writePasteboard: { _, _ in false }, sourceProbe: probe)
        backend.observeSourceState { reports.append($0) }
        #expect(reports.all == [.live])
        probe.set(locked: true)
        backend.checkSource()
        probe.set(locked: false)
        backend.checkSource()
        #expect(reports.all == [.live, .locked, .live])
        backend.stop()
        probe.set(locked: true)
        backend.checkSource()
        #expect(reports.all.count == 3)
        // After stop no new monitor starts.
        backend.observeSourceState { reports.append($0) }
        #expect(reports.all.count == 3)
    }

    /// The window server sets the lock key only while locked: absent, or not a Boolean, is unlocked (no false notice).
    @Test func theLockKeyReadsLockedOnlyWhenTrue() {
        #expect(SystemScreenSourceProbe.locked(session: ["CGSSessionScreenIsLocked": true]))
        #expect(!SystemScreenSourceProbe.locked(session: ["CGSSessionScreenIsLocked": false]))
        #expect(!SystemScreenSourceProbe.locked(session: [:]))
        #expect(!SystemScreenSourceProbe.locked(session: nil))
        #expect(!SystemScreenSourceProbe.locked(session: ["CGSSessionScreenIsLocked": "yes"]))
    }
    #endif
}
