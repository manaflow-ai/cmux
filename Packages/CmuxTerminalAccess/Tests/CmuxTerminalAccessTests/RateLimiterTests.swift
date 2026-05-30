import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Test clock that exposes a mutable offset from a fixed base
/// `ContinuousClock.Instant`. Tests advance time by mutating
/// `offsetSeconds`; no real sleeping required.
final class FakeRateLimiterClock: RateLimiterClock, @unchecked Sendable {
    private let base: ContinuousClock.Instant = .now
    private let lock = NSLock()
    private var _offsetSeconds: Double = 0

    var offsetSeconds: Double {
        get { lock.lock(); defer { lock.unlock() }; return _offsetSeconds }
        set { lock.lock(); _offsetSeconds = newValue; lock.unlock() }
    }

    func now() -> ContinuousClock.Instant {
        // Convert offsetSeconds to a Duration. `Duration.seconds` takes
        // a Double in Swift 5.9+.
        let s = offsetSeconds
        return base.advanced(by: .seconds(s))
    }
}

@Suite struct RateLimiterTests {
    @Test func allowsUpToCapacity() async throws {
        let clock = FakeRateLimiterClock()
        let limiter = RateLimiter(burstCapacity: 3, refillPerSecond: 1, clock: clock)
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "k")
        }
    }

    @Test func refillsOverTime() async throws {
        let clock = FakeRateLimiterClock()
        let limiter = RateLimiter(burstCapacity: 2, refillPerSecond: 2, clock: clock)
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "k")
        }
        clock.offsetSeconds = 1.0 // +2 tokens at 2 tps
        try await limiter.acquire(key: "k")
        try await limiter.acquire(key: "k")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "k")
        }
    }

    @Test func separateKeysAreIndependent() async throws {
        let clock = FakeRateLimiterClock()
        let limiter = RateLimiter(burstCapacity: 1, refillPerSecond: 0, clock: clock)
        try await limiter.acquire(key: "a")
        try await limiter.acquire(key: "b")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "a")
        }
    }

    @Test func bucketsAreCreatedLazilyAtFullCapacity() async throws {
        let clock = FakeRateLimiterClock()
        let limiter = RateLimiter(burstCapacity: 2, refillPerSecond: 1, clock: clock)
        try await limiter.acquire(key: "surface:1#write")
        try await limiter.acquire(key: "surface:1#write")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "surface:1#write")
        }
        // A freshly seen key gets its own full burst capacity.
        try await limiter.acquire(key: "surface:2#write")
        try await limiter.acquire(key: "surface:2#write")
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "surface:2#write")
        }
    }

    @Test func capsAtBurstCapacityEvenAfterLongIdle() async throws {
        let clock = FakeRateLimiterClock()
        let limiter = RateLimiter(burstCapacity: 3, refillPerSecond: 10, clock: clock)
        try await limiter.acquire(key: "k") // 2 left
        clock.offsetSeconds = 1000 // would refill 10k tokens; must cap at 3.
        try await limiter.acquire(key: "k") // 2 left
        try await limiter.acquire(key: "k") // 1 left
        try await limiter.acquire(key: "k") // 0 left
        await #expect(throws: TerminalAccessError.rateLimited) {
            try await limiter.acquire(key: "k")
        }
    }
}
