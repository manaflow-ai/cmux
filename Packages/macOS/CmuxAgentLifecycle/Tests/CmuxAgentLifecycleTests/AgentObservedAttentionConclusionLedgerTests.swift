import Testing
@testable import CmuxAgentLifecycle

@Suite("Observed attention conclusion ledger")
struct AgentObservedAttentionConclusionLedgerTests {
    @Test("Conclusions are scoped to an exact session and generation")
    func exactOwnershipScope() {
        let firstGeneration = AgentProcessGeneration(
            pid: 47,
            startSeconds: 106,
            startMicroseconds: 206
        )
        let replacementGeneration = AgentProcessGeneration(
            pid: 47,
            startSeconds: 107,
            startMicroseconds: 207
        )
        var ledger = AgentObservedAttentionConclusionLedger()

        ledger.record(
            source: "cursor",
            sessionId: "cursor-session-1",
            observationId: "cursor-observation-1",
            scopeId: "cursor-scope-1",
            processGeneration: firstGeneration
        )

        #expect(
            ledger.contains(
                source: "cursor",
                sessionId: "cursor-session-1",
                observationId: "cursor-observation-1",
                scopeId: "cursor-scope-1",
                processGeneration: firstGeneration
            )
        )
        #expect(
            !ledger.contains(
                source: "cursor",
                sessionId: "cursor-session-1",
                observationId: "cursor-observation-1",
                scopeId: "cursor-scope-1",
                processGeneration: replacementGeneration
            )
        )
        #expect(
            !ledger.contains(
                source: "cursor",
                sessionId: "cursor-session-2",
                observationId: "cursor-observation-1",
                scopeId: "cursor-scope-1",
                processGeneration: firstGeneration
            )
        )
    }

    @Test("A boundary concludes only equal-or-older observation epochs")
    func monotonicBoundary() {
        let generation = AgentProcessGeneration(
            pid: 48,
            startSeconds: 108,
            startMicroseconds: 208
        )
        var ledger = AgentObservedAttentionConclusionLedger()
        ledger.record(
            source: "amp",
            sessionId: "amp-session",
            observationId: nil,
            scopeId: nil,
            processGeneration: generation,
            boundaryEpoch: 12
        )

        #expect(
            ledger.contains(
                source: "amp",
                sessionId: "amp-session",
                observationId: "observation-11",
                scopeId: "scope-11",
                processGeneration: generation,
                observationEpoch: 11
            )
        )
        #expect(
            !ledger.contains(
                source: "amp",
                sessionId: "amp-session",
                observationId: "observation-13",
                scopeId: "scope-13",
                processGeneration: generation,
                observationEpoch: 13
            )
        )
    }

    @Test("Exact tombstones evict the oldest identities at the hard bound")
    func exactTombstonesAreBounded() {
        let generation = AgentProcessGeneration(
            pid: 49,
            startSeconds: 109,
            startMicroseconds: 209
        )
        var ledger = AgentObservedAttentionConclusionLedger()

        for index in 0 ..< 2_050 {
            ledger.record(
                source: "cursor",
                sessionId: "cursor-session",
                observationId: "cursor-observation-\(index)",
                scopeId: "cursor-scope-\(index)",
                processGeneration: generation
            )
        }

        #expect(
            !ledger.contains(
                source: "cursor",
                sessionId: "cursor-session",
                observationId: "cursor-observation-0",
                scopeId: "cursor-scope-0",
                processGeneration: generation
            )
        )
        #expect(
            ledger.contains(
                source: "cursor",
                sessionId: "cursor-session",
                observationId: "cursor-observation-2049",
                scopeId: "cursor-scope-2049",
                processGeneration: generation
            )
        )
    }

    @Test("Reinserted boundaries remain owned after bounded queue churn")
    func reinsertedBoundariesRemainOwned() {
        let generation = AgentProcessGeneration(
            pid: 50,
            startSeconds: 110,
            startMicroseconds: 210
        )
        var ledger = AgentObservedAttentionConclusionLedger()
        let reusedSession = "reused-boundary-session"

        ledger.record(
            source: "amp",
            sessionId: reusedSession,
            observationId: nil,
            scopeId: nil,
            processGeneration: generation,
            boundaryEpoch: 1
        )
        for index in 0 ... 4_096 {
            ledger.record(
                source: "amp",
                sessionId: "boundary-session-\(index)",
                observationId: nil,
                scopeId: nil,
                processGeneration: generation,
                boundaryEpoch: UInt64(index)
            )
        }
        ledger.record(
            source: "amp",
            sessionId: reusedSession,
            observationId: nil,
            scopeId: nil,
            processGeneration: generation,
            boundaryEpoch: 10_000
        )

        for index in 4_097 ... 8_191 {
            ledger.record(
                source: "amp",
                sessionId: "boundary-session-\(index)",
                observationId: nil,
                scopeId: nil,
                processGeneration: generation,
                boundaryEpoch: UInt64(index)
            )
        }

        #expect(
            ledger.contains(
                source: "amp",
                sessionId: reusedSession,
                observationId: "observation",
                scopeId: "scope",
                processGeneration: generation,
                observationEpoch: 10_000
            )
        )
    }
}
