import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Foundation
import Testing

/// Settings' first open after launch (2026-11-15, "Settings opens late"): the parked spare answered its
/// claim 45-88 ms after it on cmux-lawrence-2, while the host gave up after 50 ms and reloaded the live
/// document (3 of 5 first opens: the page showed at about 285 ms, 176 ms when it waited). A cold
/// acknowledgement that slow must still be taken, not reloaded.
@MainActor @Suite(.serialized) struct ColdClaimAcknowledgementTests {
    /// The slowest cold acknowledgement measured in the app (bench-settings-open.py, 20 launches).
    static let coldAcknowledgement: Duration = .milliseconds(88)

    @Test func aClaimAnsweredAsLateAsACold88MsOneIsNotReloaded() async throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let options = PageEngineOptions(requiresWebKit: .pooledInstantOpen)
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), policy: policy,
                                options: options, activity: { 0 }, isTrackingMenu: { false },
                                engineDecision: { _, _ in .webKit(.pooledInstantOpen) })
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release); window.close() }
        pool.follow(window)
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in pool.onSpareReady = { _ in done(true) } }
        }
        let spare = try #require(pool.spare, "no parked Settings spare")
        // A parked spare waits seconds or more in the app: its document has settled (SettingsOpensFromParkedSpareTests).
        try await Task.sleep(for: .milliseconds(500))
        let clock = StepClock()
        spare.claimState.clock = clock
        let page = try #require(pool.claim(.settings, routes: [], route: "#/settings/general", options: options, window: window, focus: false))
        // The cold answer is still on its way when this much of the claim's clock has passed.
        clock.advance(by: Self.coldAcknowledgement)
        let start = ContinuousClock.now
        while page.lastClaim == nil, ContinuousClock.now - start < .seconds(2) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(page.lastClaim?.path == .acknowledged,
                "a live parked document answering \(Self.coldAcknowledgement) after its claim was reloaded: \(String(describing: page.lastClaim))")
    }
}

/// A clock that moves only by ``advance(by:)`` (CmuxNextPagesTests has no ManualClock dependency).
private final class StepClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(Instant, CheckedContinuation<Void, any Error>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let due = lock.withLock { () -> Bool in
                if deadline <= current { return true }
                sleepers.append((deadline, continuation))
                return false
            }
            if due { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.0 <= current }.map(\.1)
            sleepers.removeAll { $0.0 <= current }
            return ready
        }
        due.forEach { $0.resume() }
    }
}
