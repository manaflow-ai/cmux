import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact LRU cache")
struct ChatArtifactLRUCacheTests {
    @Test("a cache hit protects the entry from capacity eviction")
    func hitUpdatesRecency() {
        var cache = ChatArtifactLRUCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "one")
        cache.insert(2, forKey: "two")

        #expect(cache.value(forKey: "one") == 1)
        cache.insert(3, forKey: "three")

        #expect(cache.count == 2)
        #expect(cache.value(forKey: "one") == 1)
        #expect(cache.value(forKey: "two") == nil)
        #expect(cache.value(forKey: "three") == 3)
    }
}
