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
    private var values: [String]
    private(set) var count = 0

    init(values: [String]) {
        self.values = values
    }

    func next() -> String? {
        count += 1
        return values.isEmpty ? nil : values.removeFirst()
    }
}
