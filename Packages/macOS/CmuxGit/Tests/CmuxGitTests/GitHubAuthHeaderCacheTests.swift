import Foundation
import Testing
@testable import CmuxGit

@Suite(.serialized)
struct GitHubAuthHeaderCacheTests {
    @Test func successfulResolutionRemainsCachedAfterFiveMinutes() async {
        let clock = MutableDateClock(initial: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = GitHubAuthHeaderCache(now: { clock.now })
        let resolver = HeaderResolutionCounter(values: ["Bearer first", "Bearer second"])

        let first = await cache.header {
            await resolver.next()
        }
        clock.advance(by: 6 * 60)
        let second = await cache.header {
            await resolver.next()
        }

        #expect(first?.value == "Bearer first")
        #expect(second?.value == "Bearer first")
        #expect(await resolver.count == 1)
    }

    @Test func failedResolutionUsesExponentialBackoff() async {
        let clock = MutableDateClock(initial: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = GitHubAuthHeaderCache(
            failureBackoffBase: 60,
            failureBackoffMaximum: 15 * 60,
            now: { clock.now }
        )
        let resolver = HeaderResolutionCounter(values: [nil, nil, "Bearer recovered"])

        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 1)

        clock.advance(by: 60)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 2)

        // The second failure backs off for two minutes, rather than prompting
        // again on the next one-minute sidebar refresh.
        clock.advance(by: 119)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 2)
        clock.advance(by: 1)
        #expect((await cache.header { await resolver.next() })?.value == "Bearer recovered")
        #expect(await resolver.count == 3)
    }

    @Test func matchingInvalidationAllowsCredentialRefresh() async {
        let cache = GitHubAuthHeaderCache()
        let resolver = HeaderResolutionCounter(values: ["Bearer first", "Bearer second"])

        let first = await cache.header { await resolver.next() }
        #expect(first?.value == "Bearer first")
        guard let first else {
            Issue.record("expected the first credential lease")
            return
        }
        await cache.invalidate(
            GitHubAuthHeaderLease(value: "Bearer unrelated", generation: first.generation)
        )
        #expect((await cache.header { await resolver.next() }) == first)
        #expect(await resolver.count == 1)

        await cache.invalidate(first)
        #expect((await cache.header { await resolver.next() })?.value == "Bearer second")
        #expect(await resolver.count == 2)
    }

    @Test func authenticationFailuresBackOffAcrossCredentialRefreshes() async {
        let clock = MutableDateClock(initial: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = GitHubAuthHeaderCache(
            failureBackoffBase: 60,
            failureBackoffMaximum: 15 * 60,
            now: { clock.now }
        )
        let resolver = HeaderResolutionCounter(
            values: ["Bearer first", "Bearer second", "Bearer third", "Bearer fourth"]
        )

        let first = await cache.header { await resolver.next() }
        #expect(first?.value == "Bearer first")
        guard let first else {
            Issue.record("expected the first credential lease")
            return
        }
        await cache.invalidate(first)
        let second = await cache.header { await resolver.next() }
        #expect(second?.value == "Bearer second")
        guard let second else {
            Issue.record("expected the second credential lease")
            return
        }
        await cache.recordFailure(second)

        clock.advance(by: 60)
        let third = await cache.header { await resolver.next() }
        #expect(third?.value == "Bearer third")
        guard let third else {
            Issue.record("expected the third credential lease")
            return
        }
        await cache.recordFailure(third)

        // The second rejected credential advances the backoff to two minutes.
        clock.advance(by: 119)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 3)
        clock.advance(by: 1)
        #expect((await cache.header { await resolver.next() })?.value == "Bearer fourth")
        #expect(await resolver.count == 4)
    }

    @Test func staleSameValueLeasesCannotClearOrOvercountBackoff() async {
        let clock = MutableDateClock(initial: Date(timeIntervalSince1970: 1_800_000_000))
        let cache = GitHubAuthHeaderCache(
            failureBackoffBase: 60,
            failureBackoffMaximum: 15 * 60,
            now: { clock.now }
        )
        let resolver = HeaderResolutionCounter(
            values: ["Bearer same", "Bearer same", "Bearer same"]
        )

        let first = await cache.header { await resolver.next() }
        guard let first else {
            Issue.record("expected the first credential lease")
            return
        }
        await cache.invalidate(first)
        let second = await cache.header { await resolver.next() }
        guard let second else {
            Issue.record("expected the replacement credential lease")
            return
        }
        await cache.recordFailure(second)
        // A duplicate 401 and a delayed 200 from the old generation are both
        // ignored, so one polling pass advances the streak only once.
        await cache.recordFailure(second)
        await cache.recordSuccess(first)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 2)

        clock.advance(by: 60)
        let third = await cache.header { await resolver.next() }
        guard let third else {
            Issue.record("expected the next credential lease")
            return
        }
        await cache.recordFailure(third)
        clock.advance(by: 119)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 3)
    }
}

/// A test-only clock whose synchronous read can safely cross the cache actor.
/// The lock protects the mutable instant while the cache invokes the closure
/// from its isolated context.
private final class MutableDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(initial: Date) {
        instant = initial
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        instant = instant.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private actor HeaderResolutionCounter {
    private var values: [String?]
    private(set) var count = 0

    init(values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        count += 1
        return values.isEmpty ? nil : values.removeFirst()
    }
}
