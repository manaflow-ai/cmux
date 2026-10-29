import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// `key.frame.<target>`: each committed key records one sample, from its key-down (the
/// event's timestamp) to the end of its commit, for its target; a missed key, a key while the keystroke-timing gate
/// is closed and a runtime with no store record nothing. The signposter's clock is a counter the test moves.
@MainActor
struct KeyFrameHistogramTests {
    /// `CLOCK_UPTIME_RAW` as a counter.
    private nonisolated final class Uptime: Sendable {
        private let nanos = Atomic<UInt64>(1_000_000_000)

        func advance(micros: UInt64) { _ = nanos.wrappingAdd(micros * 1_000, ordering: .relaxed) }

        var clock: TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in nanos.load(ordering: .relaxed) }, continuousNow: { ContinuousClock.now }))
        }
    }

    private static let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "dev", osVersion: "26.1.0",
                                                hardwareClass: "Mac16,10",
                                                buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))

    /// Key-frame signposts on a fresh runtime with a store (`store: false`: none), the store and the clock.
    private static func rig(store attach: Bool = true, secureEventInput: @escaping () -> Bool = { false })
        -> (keyFrames: KeyFrameSignpost, store: MetricsStore, uptime: Uptime) {
        let trace = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile)
        if attach { store.attach(to: trace) }
        let uptime = Uptime()
        let key = Signposter(category: .key, mirror: SignpostMetricKitMirror(), trace: trace, clock: uptime.clock)
        return (KeyFrameSignpost(signposter: key, secureEventInput: secureEventInput), store, uptime)
    }

    private static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    @Test("A committed key records key.frame for its target, from its key-down to the end of its commit")
    func committedKeysRecordTheirTarget() throws {
        let (keyFrames, store, uptime) = Self.rig()
        keyFrames.begin(target: .terminal, eventTimestamp: 10, now: 10.002) // it waited 2 ms in the queue
        uptime.advance(micros: 3_000)
        keyFrames.begin(target: .view, eventTimestamp: 0) // no timestamp: from its dispatch
        uptime.advance(micros: 1_000)
        keyFrames.runLoopReached(.beforeWaiting)

        let terminal = try #require(Self.histogram(.keyFrame(.terminal), in: store))
        #expect(terminal.count == 1 && terminal.sum == 6_000, "2 ms queued + 3 ms + 1 ms to the commit")
        let view = try #require(Self.histogram(.keyFrame(.view), in: store))
        #expect(view.count == 1 && view.sum == 1_000)
        #expect(keyFrames.openCount == 0)
    }

    @Test("Each committed key reaches committedKey with its key.frame time; a missed key does not")
    func committedKeysReachTheObserver() {
        let (keyFrames, _, uptime) = Self.rig()
        var seen: [UInt64] = []
        keyFrames.committedKey = { seen.append($0) }
        keyFrames.begin(target: .terminal, eventTimestamp: 10, now: 10.002) // it waited 2 ms in the queue
        uptime.advance(micros: 78_000)
        keyFrames.runLoopReached(.beforeWaiting)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        uptime.advance(micros: 500_000)
        keyFrames.runLoopReached(.afterWaiting)
        #expect(seen == [80_000])
    }

    @Test("A key ended as missed records nothing: its time would hold the run loop's sleep")
    func aMissedKeyRecordsNothing() {
        let (keyFrames, store, uptime) = Self.rig()
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        uptime.advance(micros: 500_000)
        keyFrames.runLoopReached(.afterWaiting)
        #expect(keyFrames.openCount == 0)
        #expect(store.delta().isEmpty)
    }

    @Test("While secure event input is on, a key records no key.frame")
    func secureEventInputRecordsNothing() {
        let (keyFrames, store, _) = Self.rig(secureEventInput: { true })
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        keyFrames.runLoopReached(.beforeWaiting)
        #expect(store.delta().isEmpty)
    }

    @Test("Without a store a committed key still ends and records nothing")
    func noStoreRecordsNothing() {
        let (keyFrames, store, _) = Self.rig(store: false)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        keyFrames.runLoopReached(.exit)
        #expect(keyFrames.openCount == 0)
        #expect(store.delta().isEmpty)
    }
}
