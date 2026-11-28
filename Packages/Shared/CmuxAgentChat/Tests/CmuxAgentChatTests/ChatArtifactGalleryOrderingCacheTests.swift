import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery ordering cache")
struct ChatArtifactGalleryOrderingCacheTests {
    @Test("same generation reuses its ordering and a new generation invalidates it")
    func generationReuseAndInvalidation() async {
        let cache = ChatArtifactGalleryOrderingCache()
        let original = [
            item("/older", seq: 1),
            item("/newer", seq: 2),
        ]
        let changedWithoutGeneration = [item("/unexpected", seq: 100)]
        let nextGeneration = [
            item("/latest", seq: 3),
            item("/newer", seq: 2),
        ]

        let first = await cache.ordered(original, indexID: "session", generation: "one")
        let reused = await cache.ordered(
            changedWithoutGeneration,
            indexID: "session",
            generation: "one"
        )
        let invalidated = await cache.ordered(
            nextGeneration,
            indexID: "session",
            generation: "two"
        )

        #expect(first.map(\.path) == ["/newer", "/older"])
        #expect(reused == first)
        #expect(invalidated.map(\.path) == ["/latest", "/newer"])
    }

    private func item(_ path: String, seq: Int) -> ChatArtifactIndexedReference {
        ChatArtifactIndexedReference(
            path: path,
            provenance: .referenced,
            lastReferencedSeq: seq
        )
    }
}
