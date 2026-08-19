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

        #expect(first == "Bearer first")
        #expect(second == "Bearer first")
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
        #expect(await cache.header { await resolver.next() } == "Bearer recovered")
        #expect(await resolver.count == 3)
    }

    @Test func matchingInvalidationAllowsCredentialRefresh() async {
        let cache = GitHubAuthHeaderCache()
        let resolver = HeaderResolutionCounter(values: ["Bearer first", "Bearer second"])

        #expect(await cache.header { await resolver.next() } == "Bearer first")
        await cache.invalidate(ifMatching: "Bearer unrelated")
        #expect(await cache.header { await resolver.next() } == "Bearer first")
        #expect(await resolver.count == 1)

        await cache.invalidate(ifMatching: "Bearer first")
        #expect(await cache.header { await resolver.next() } == "Bearer second")
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

        #expect(await cache.header { await resolver.next() } == "Bearer first")
        await cache.invalidate(ifMatching: "Bearer first")
        #expect(await cache.header { await resolver.next() } == "Bearer second")
        await cache.recordFailure(ifMatching: "Bearer second")

        clock.advance(by: 60)
        #expect(await cache.header { await resolver.next() } == "Bearer third")
        await cache.recordFailure(ifMatching: "Bearer third")

        // The second rejected credential advances the backoff to two minutes.
        clock.advance(by: 119)
        #expect(await cache.header { await resolver.next() } == nil)
        #expect(await resolver.count == 3)
        clock.advance(by: 1)
        #expect(await cache.header { await resolver.next() } == "Bearer fourth")
        #expect(await resolver.count == 4)
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
