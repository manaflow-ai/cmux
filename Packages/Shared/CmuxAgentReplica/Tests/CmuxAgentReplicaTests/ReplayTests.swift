import Foundation
import Testing
@testable import CmuxAgentReplica

@MainActor @Suite struct ReplayTests {
    @Test func replayRoundTripEncodeDecodeProducesIdenticalStoreState() throws {
        let records = [
            ReplicaReplayRecord(tick: 1, origin: .resync, delta: .sessionUpserted(ReplicaTestSupport.snapshot(version: 1))),
            ReplicaReplayRecord(tick: 2, origin: .live, delta: .entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1), ReplicaTestSupport.entry(2)])),
            ReplicaReplayRecord(tick: 3, origin: .live, delta: .entryReplaced(ReplicaTestSupport.entry(2, version: 2, hash: 22))),
        ]
        let encoded = try ReplicaReplayLog(records: records).encodeJSONL()
        let decoded = ReplicaReplayLog.decodeJSONL(encoded)

        #expect(decoded.records == records)
        #expect(decoded.skippedLineCount == 0)
        #expect(state(after: records) == state(after: decoded.records))
    }

    @Test func invalidJsonLinesAreSkippedWithCounter() {
        let data = Data(#"{"tick":1,"origin":"live","delta":{"kind":"futureMutation"}}"#.utf8)
            + Data("\nnot-json\n".utf8)
        let log = ReplicaReplayLog.decodeJSONL(data)

        #expect(log.records == [ReplicaReplayRecord(tick: 1, origin: .live, delta: .unknown(kind: "futureMutation"))])
        #expect(log.skippedLineCount == 1)
    }

    @Test func fixtureFilesDecodeAndFeedStores() throws {
        for name in ["normal-session-lifecycle", "rotation-reset", "epoch-change-pending-tickets"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
            let data = try Data(contentsOf: url)
            let log = ReplicaReplayLog.decodeJSONL(data)
            #expect(log.skippedLineCount == 0)
            #expect(!log.records.isEmpty)

            let directory = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "fixture"))
            let conversation = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
            FixtureReplicaSource(records: log.records).feed(directory: directory, conversations: [ReplicaTestSupport.session: conversation])
            #expect(directory.lastAppliedOrigin != nil || conversation.lastAppliedOrigin != nil)
        }
    }

    @Test func epochChangeFixtureKeepsPendingTicketAcrossManualEpochDrop() throws {
        let url = try #require(Bundle.module.url(forResource: "epoch-change-pending-tickets", withExtension: "jsonl"))
        let log = ReplicaReplayLog.decodeJSONL(try Data(contentsOf: url))
        let directory = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "e1"))
        let conversation = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())

        FixtureReplicaSource(records: Array(log.records.prefix(2))).feed(directory: directory, conversations: [ReplicaTestSupport.session: conversation])
        #expect(conversation.sendTickets.count == 1)
        #expect(conversation.asks.count == 1)

        directory.handleEpochChange(to: ReplicaEpoch(rawValue: "e2"))
        conversation.handleEpochChange(to: ReplicaEpoch(rawValue: "e2"))
        FixtureReplicaSource(records: Array(log.records.dropFirst(2))).feed(directory: directory, conversations: [ReplicaTestSupport.session: conversation])

        #expect(directory.sessions.count == 1)
        #expect(conversation.sendTickets.count == 1)
        #expect(conversation.asks.isEmpty)
    }

    @Test func applyingAnyPrefixTwiceIsIdempotentAndIndependentEntitiesCommute() {
        let records = propertyRecords()
        for count in 0...records.count {
            let prefix = Array(records.prefix(count))
            #expect(state(after: prefix + prefix) == state(after: prefix))
        }

        let setup = Array(records.prefix(2))
        let independentTail = Array(records.dropFirst(2).prefix(4))
        let expected = state(after: setup + independentTail)
        for permutation in permutations(of: independentTail) {
            #expect(state(after: setup + permutation) == expected)
        }
    }

    private func state(after records: [ReplicaReplayRecord]) -> ReplayState {
        let directory = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "e1"))
        let conversation = ConversationReplica(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, clock: ReplicaTestSupport.clock())
        let otherConversation = ConversationReplica(sessionID: ReplicaTestSupport.otherSession, journalID: ReplicaTestSupport.otherJournal, clock: ReplicaTestSupport.clock())
        FixtureReplicaSource(records: records).feed(
            directory: directory,
            conversations: [ReplicaTestSupport.session: conversation, ReplicaTestSupport.otherSession: otherConversation]
        )
        return ReplayState(
            sessions: directory.sessions,
            conversation: conversation.state,
            otherConversation: otherConversation.state
        )
    }

    private func propertyRecords() -> [ReplicaReplayRecord] {
        [
            ReplicaReplayRecord(tick: 1, origin: .resync, delta: .sessionUpserted(ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, version: 1))),
            ReplicaReplayRecord(tick: 2, origin: .resync, delta: .sessionUpserted(ReplicaTestSupport.snapshot(id: ReplicaTestSupport.otherSession, version: 1))),
            ReplicaReplayRecord(tick: 3, origin: .live, delta: .sessionUpserted(ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .working, version: 2))),
            ReplicaReplayRecord(tick: 4, origin: .live, delta: .entriesAppended(journalID: ReplicaTestSupport.otherJournal, entries: [
                ReplicaTestSupport.entry(1, journalID: ReplicaTestSupport.otherJournal),
            ])),
            ReplicaReplayRecord(tick: 5, origin: .live, delta: .entriesAppended(journalID: ReplicaTestSupport.journal, entries: [ReplicaTestSupport.entry(1)])),
            ReplicaReplayRecord(tick: 6, origin: .live, delta: .sessionUpserted(ReplicaTestSupport.snapshot(id: ReplicaTestSupport.otherSession, phase: .working, version: 2))),
        ]
    }

    private func permutations(of records: [ReplicaReplayRecord]) -> [[ReplicaReplayRecord]] {
        guard let first = records.first else {
            return [[]]
        }
        let rest = Array(records.dropFirst())
        return permutations(of: rest).flatMap { tail in
            (0...tail.count).map { index in
                var output = tail
                output.insert(first, at: index)
                return output
            }
        }
    }
}

private struct ReplayState: Hashable {
    let sessions: [AgentSessionSnapshot]
    let conversation: ConversationReplicaState
    let otherConversation: ConversationReplicaState
}
