import Testing
@testable import CmuxAgentLifecycle

@Suite("Observed agent attention registry")
struct AgentObservedAttentionRegistryTests {
    @Test func evictsOldestObservationAtTheHardLimit() throws {
        var registry = AgentObservedAttentionRegistry<String>(
            maximumCount: 2
        )
        let first = record(index: 1)
        let second = record(index: 2)
        let third = record(index: 3)

        let firstInsertion = registry.insert(first)
        #expect(firstInsertion?.isEmpty == true)
        let secondInsertion = registry.insert(second)
        #expect(secondInsertion?.isEmpty == true)
        let thirdInsertion = registry.insert(third)
        let evicted = try #require(thirdInsertion)

        #expect(evicted.map(\.key) == [first.key])
        #expect(registry.count == 2)
        #expect(registry.record(for: first.key) == nil)
        #expect(registry.record(for: second.key)?.target == "target-2")
        #expect(registry.record(for: third.key)?.target == "target-3")
    }

    @Test func ownerTeardownReturnsOnlyMatchingVisibleState() {
        var registry = AgentObservedAttentionRegistry<String>()
        let first = record(index: 1)
        let second = record(index: 2)
        _ = registry.insert(first)
        _ = registry.insert(second)

        let removed = registry.remove {
            $0.key.sessionId == first.key.sessionId
        }

        #expect(removed.map(\.key) == [first.key])
        #expect(registry.count == 1)
        #expect(registry.record(for: second.key)?.target == "target-2")
    }

    @Test func duplicateBeginDoesNotReplaceItsOriginalTarget() {
        var registry = AgentObservedAttentionRegistry<String>()
        let first = record(index: 1)
        _ = registry.insert(first)
        let duplicate = AgentObservedAttentionRecord(
            key: first.key,
            scopeId: first.scopeId,
            target: "replacement"
        )

        let duplicateInsertion = registry.insert(duplicate)
        #expect(duplicateInsertion == nil)
        #expect(registry.record(for: first.key)?.target == first.target)
    }

    private func record(
        index: Int
    ) -> AgentObservedAttentionRecord<String> {
        AgentObservedAttentionRecord(
            key: AgentObservedAttentionKey(
                source: "amp",
                sessionId: "session-\(index)",
                observationId: "observation-\(index)",
                processGeneration: AgentProcessGeneration(
                    pid: 100 + Int32(index),
                    startSeconds: Int64(index),
                    startMicroseconds: 0
                )
            ),
            scopeId: "scope-\(index)",
            target: "target-\(index)"
        )
    }
}
