import CmuxNextCompat
import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

@Suite struct LagSpikeReporterTests {
    private static let ms: UInt64 = 1_000_000

    @Test func shortSpikesAreNeverAdmitted() {
        var limiter = LagSpikeRateLimiter(minimumNanos: 250 * Self.ms, capacity: 3, refillNanos: 1_000 * Self.ms)
        let admitted1 = limiter.admit(durationNanos: 249 * Self.ms, nowNanos: 0)
        #expect(!admitted1)
        let admitted2 = limiter.admit(durationNanos: 250 * Self.ms, nowNanos: 0)
        #expect(admitted2)
    }

    @Test func aBurstIsCappedThenRefillsOverTime() {
        var limiter = LagSpikeRateLimiter(minimumNanos: 1, capacity: 3, refillNanos: 1_000 * Self.ms)
        let burst = (0..<10).map { _ in limiter.admit(durationNanos: 300 * Self.ms, nowNanos: 10 * Self.ms) }
        #expect(burst.filter { $0 }.count == 3)
        let admitted3 = limiter.admit(durationNanos: 300 * Self.ms, nowNanos: 900 * Self.ms)
        #expect(!admitted3)
        let admitted4 = limiter.admit(durationNanos: 300 * Self.ms, nowNanos: 1_010 * Self.ms)
        #expect(admitted4)
        let admitted5 = limiter.admit(durationNanos: 300 * Self.ms, nowNanos: 1_020 * Self.ms)
        #expect(!admitted5)
        // A long quiet time refills only up to the capacity.
        let later = (0..<10).map { _ in limiter.admit(durationNanos: 300 * Self.ms, nowNanos: 100_000 * Self.ms) }
        #expect(later.filter { $0 }.count == 3)
    }

    @Test func eventNamesABucketTagsAndNoStackFingerprint() {
        let spike = LagSpikeEvent(duration: .milliseconds(640), cpu: .milliseconds(20), addresses: [],
                                  context: ["windows": "2"])
        #expect(spike.bucket == "500ms-1s")
        #expect(spike.mostlyBlocked)
        let event = spike.event()
        #expect(event.level == .warning)
        #expect(event.exceptions?.first?.type == "MainThreadStall")
        #expect(event.exceptions?.first?.value == "main thread stalled 500ms-1s")
        #expect(event.tags?["hang_source"] == "main_thread_stall")
        #expect(event.tags?["stall_blocked"] == "yes")
        #expect(event.extra?["stall_ms"] as? Int == 640)
        #expect(event.extra?["windows"] as? String == "2")
        #expect(event.fingerprint == ["main_thread_stall", "no_stack", "500ms-1s"])
    }

    @Test func eventWithAStackKeepsDefaultGroupingAndImages() {
        // A real code address (malloc in libsystem), so dladdr finds its image.
        let address = UInt(bitPattern: dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc"))
        #expect(address != 0)
        let event = LagSpikeEvent(duration: .milliseconds(300), cpu: .milliseconds(290), addresses: [address]).event()
        #expect(event.fingerprint == nil)
        #expect(event.exceptions?.first?.stacktrace?.frames.count == 1)
        #expect(event.debugMeta?.isEmpty == false)
        #expect(event.tags?["stall_blocked"] == "no")
    }

    @Test func reporterSendsAdmittedSpikesOffTheCallerWithContext() async {
        let sent = SpikeRecorder()
        let clock = SpikeClock()
        let reporter = LagSpikeReporter(limiter: LagSpikeRateLimiter(minimumNanos: 250 * Self.ms, capacity: 1, refillNanos: 60_000 * Self.ms),
                                        isEnabled: { true }, sink: { sent.add($0) }, uptime: { clock.now.withLock { $0 } })
        reporter.setContextProvider { ["windows": "3"] }
        #expect(!reporter.noteStall(duration: .milliseconds(100), cpu: .milliseconds(100), addresses: []))
        #expect(reporter.noteStall(duration: .milliseconds(400), cpu: .milliseconds(400), addresses: []))
        #expect(!reporter.noteStall(duration: .milliseconds(900), cpu: .milliseconds(900), addresses: []), "rate-limited")
        let spikes = await sent.wait(for: 1)
        #expect(spikes.map(\.context) == [["windows": "3"]])
        #expect(spikes.first?.duration == .milliseconds(400))
    }

    @Test func reporterDoesNothingWhileReportingIsOff() {
        let reporter = LagSpikeReporter(limiter: LagSpikeRateLimiter(), isEnabled: { false }, sink: { _ in Issue.record("sent while off") })
        #expect(!reporter.noteStall(duration: .seconds(1), cpu: .seconds(1), addresses: []))
    }

    @Test func thresholdComesFromTheEnvironmentWithAFloor() {
        #expect(LagSpikeReporter.environmentMinimumNanos([:]) == 250 * Self.ms)
        #expect(LagSpikeReporter.environmentMinimumNanos(["CMUX_NEXT_LAG_REPORT_MS": "500"]) == 500 * Self.ms)
        #expect(LagSpikeReporter.environmentMinimumNanos(["CMUX_NEXT_LAG_REPORT_MS": "5"]) == 50 * Self.ms)
    }

}

/// Collects sent spikes; `wait(for:)` resumes when `count` arrived.
private actor SpikeStore {
    var spikes: [LagSpikeEvent] = []
    var waiters: [(Int, CheckedContinuation<[LagSpikeEvent], Never>)] = []

    func add(_ spike: LagSpikeEvent) {
        spikes.append(spike)
        let ready = waiters.filter { $0.0 <= spikes.count }
        waiters.removeAll { $0.0 <= spikes.count }
        for (_, continuation) in ready { continuation.resume(returning: spikes) }
    }

    func wait(for count: Int) async -> [LagSpikeEvent] {
        if spikes.count >= count { return spikes }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private nonisolated final class SpikeRecorder: Sendable {
    let store = SpikeStore()
    func add(_ spike: LagSpikeEvent) { Task { await store.add(spike) } }
    func wait(for count: Int) async -> [LagSpikeEvent] { await store.wait(for: count) }
}

/// A fixed monotonic clock (a class: `Mutex` cannot be captured).
private nonisolated final class SpikeClock: Sendable {
    let now = Mutex<UInt64>(0)
}
