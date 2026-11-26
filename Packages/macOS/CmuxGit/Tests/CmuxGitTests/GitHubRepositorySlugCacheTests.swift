import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitHubRepositorySlugCacheTests {
    /// Counts how often discovery ran, so the tests can assert the cache spared
    /// the expensive call rather than just returning the right answer.
    private actor DiscoveryRecorder {
        private(set) var callCount = 0
        private var slugsByDirectory: [String: String?]

        init(slugsByDirectory: [String: String?]) {
            self.slugsByDirectory = slugsByDirectory
        }

        func discover(_ directory: String) -> String? {
            callCount += 1
            return slugsByDirectory[directory] ?? nil
        }

        func setSlug(_ slug: String?, forDirectory directory: String) {
            slugsByDirectory[directory] = slug
        }
    }

    /// A clock the test advances by hand, so entry expiry is exercised by
    /// moving time rather than by sleeping and hoping.
    ///
    /// Locking is `NSLock` rather than `Synchronization.Mutex`: this package
    /// targets macOS 14 and `Mutex` needs macOS 15.
    private final class TestClock: Sendable {
        private let origin = ContinuousClock().now
        private let lock = NSLock()
        nonisolated(unsafe) private var offset: Duration = .zero

        var now: @Sendable () -> ContinuousClock.Instant {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return origin.advanced(by: offset)
            }
        }

        func advance(by duration: Duration) {
            lock.lock()
            defer { lock.unlock() }
            offset += duration
        }
    }

    /// Holds a discovery call open until the test lets it finish, so the
    /// shared-lookup assertion rests on ordering instead of on timing.
    private actor DiscoveryGate {
        private var hasStarted = false
        private var isReleased = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func signalStarted() {
            hasStarted = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func release() {
            isReleased = true
            for waiter in releaseWaiters { waiter.resume() }
            releaseWaiters.removeAll()
        }

        func waitUntilReleased() async {
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    @Test func resolvesADirectoryOnceAndServesTheRestFromCache() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: ["/work": "manaflow-ai/cmux"])
        let cache = GitHubRepositorySlugCache { await recorder.discover($0) }

        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        #expect(await recorder.callCount == 1)
    }

    @Test func separateDirectoriesResolveSeparately() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: [
            "/work": "manaflow-ai/cmux",
            "/other": "manaflow-ai/cmuxterm-hq",
        ])
        let cache = GitHubRepositorySlugCache { await recorder.discover($0) }

        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        #expect(await cache.slug(forDirectory: "/other") == "manaflow-ai/cmuxterm-hq")
        #expect(await recorder.callCount == 2)
    }

    /// A directory with no GitHub remote must also be remembered, or every
    /// pointer event in a non-GitHub checkout pays for discovery again.
    @Test func aMissIsCachedToo() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: [:])
        let cache = GitHubRepositorySlugCache { await recorder.discover($0) }

        #expect(await cache.slug(forDirectory: "/plain") == nil)
        #expect(await cache.slug(forDirectory: "/plain") == nil)
        #expect(await recorder.callCount == 1)
    }

    @Test func concurrentCallersShareOneLookup() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: ["/work": "manaflow-ai/cmux"])
        let gate = DiscoveryGate()
        let cache = GitHubRepositorySlugCache { directory in
            await gate.signalStarted()
            await gate.waitUntilReleased()
            return await recorder.discover(directory)
        }

        async let firstSlug = cache.slug(forDirectory: "/work")

        // The first caller has entered the actor and registered its lookup, so
        // every later caller is bound to find that lookup pending.
        await gate.waitUntilStarted()

        let laterSlugs = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<7 {
                group.addTask { await cache.slug(forDirectory: "/work") }
            }

            // Hold discovery open until all seven have actually joined the
            // in-flight lookup. Releasing earlier would let them fall through
            // to a fresh cache entry instead, and the call-count assertion
            // below would pass without the shared-lookup path ever running.
            let deadline = ContinuousClock().now + .seconds(10)
            while await cache.joinedPendingLookupCount < 7,
                  ContinuousClock().now < deadline {
                await Task.yield()
            }
            await gate.release()

            return await group.reduce(into: [String?]()) { $0.append($1) }
        }

        let slugs = await [firstSlug] + laterSlugs
        #expect(slugs.count == 8)
        #expect(slugs.allSatisfy { $0 == "manaflow-ai/cmux" })
        #expect(await recorder.callCount == 1)
        #expect(await cache.joinedPendingLookupCount == 7)
    }

    /// Invalidating mid-lookup must not let the pre-invalidation answer land in
    /// the cache once that lookup finishes, or the invalidation did nothing.
    @Test func removeAllDuringAnInFlightLookupDropsTheStaleAnswer() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: ["/work": "old/name"])
        let gate = DiscoveryGate()
        let cache = GitHubRepositorySlugCache { directory in
            await gate.signalStarted()
            await gate.waitUntilReleased()
            return await recorder.discover(directory)
        }

        async let firstSlug = cache.slug(forDirectory: "/work")
        await gate.waitUntilStarted()

        // Something invalidated the cache while this lookup was still out.
        await cache.removeAll()
        await gate.release()

        // The caller that asked before the invalidation still gets its answer.
        #expect(await firstSlug == "old/name")

        // Now the remote really does resolve differently. A caller arriving
        // after the invalidation must re-resolve rather than be handed the
        // answer the invalidated lookup wrote back.
        await recorder.setSlug("new/name", forDirectory: "/work")
        #expect(await cache.slug(forDirectory: "/work") == "new/name")
        #expect(await recorder.callCount == 2)
    }

    /// A remote added after launch has to become visible without a restart.
    @Test func anExpiredEntryIsResolvedAgain() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: [:])
        let clock = TestClock()
        let cache = GitHubRepositorySlugCache(
            entryLifetime: .seconds(600),
            discover: { await recorder.discover($0) },
            now: clock.now
        )

        #expect(await cache.slug(forDirectory: "/work") == nil)
        await recorder.setSlug("manaflow-ai/cmux", forDirectory: "/work")

        // Still inside the lifetime, so the stale miss is served from cache.
        clock.advance(by: .seconds(599))
        #expect(await cache.slug(forDirectory: "/work") == nil)
        #expect(await recorder.callCount == 1)

        clock.advance(by: .seconds(2))
        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        #expect(await recorder.callCount == 2)
    }

    @Test func removeAllForcesAFreshLookup() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: ["/work": "manaflow-ai/cmux"])
        let cache = GitHubRepositorySlugCache { await recorder.discover($0) }

        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        await cache.removeAll()
        #expect(await cache.slug(forDirectory: "/work") == "manaflow-ai/cmux")
        #expect(await recorder.callCount == 2)
    }
}
