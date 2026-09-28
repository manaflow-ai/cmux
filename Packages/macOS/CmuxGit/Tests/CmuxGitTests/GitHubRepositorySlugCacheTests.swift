import CmuxGit
import Foundation
import Testing

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
        let cache = GitHubRepositorySlugCache { directory in
            try? await Task.sleep(for: .milliseconds(20))
            return await recorder.discover(directory)
        }

        let slugs = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.slug(forDirectory: "/work") }
            }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }

        #expect(slugs.allSatisfy { $0 == "manaflow-ai/cmux" })
        #expect(await recorder.callCount == 1)
    }

    /// A remote added after launch has to become visible without a restart.
    @Test func anExpiredEntryIsResolvedAgain() async {
        let recorder = DiscoveryRecorder(slugsByDirectory: [:])
        let cache = GitHubRepositorySlugCache(entryLifetime: .milliseconds(1)) {
            await recorder.discover($0)
        }

        #expect(await cache.slug(forDirectory: "/work") == nil)
        await recorder.setSlug("manaflow-ai/cmux", forDirectory: "/work")
        try? await Task.sleep(for: .milliseconds(20))

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
