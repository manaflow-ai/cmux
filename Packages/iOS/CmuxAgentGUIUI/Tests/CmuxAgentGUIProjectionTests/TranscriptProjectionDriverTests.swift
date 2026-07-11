@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
import Foundation
import Testing

@MainActor
@Suite struct TranscriptProjectionDriverTests {
    @Test func startAndStopOpenAndCloseConversationIdempotently() {
        let engine = AgentSyncEngine(transport: FixtureSyncTransport())
        let driver = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { _ in }

        driver.start()
        driver.start()
        #expect(engine.conversations[Self.sessionID] != nil)
        #expect(engine.conversations.count == 1)

        driver.stop()
        driver.stop()
        #expect(engine.conversations[Self.sessionID] == nil)
        #expect(engine.conversations.isEmpty)
    }

    @Test func stoppingOlderDriverKeepsOverlappingDriverConversationOpen() throws {
        let engine = AgentSyncEngine(transport: FixtureSyncTransport())
        let driverA = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { _ in }
        let driverB = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { _ in }

        driverA.start()
        let conversation = try #require(engine.conversations[Self.sessionID])
        driverB.start()
        driverA.stop()

        #expect(engine.conversations[Self.sessionID] === conversation)
        driverB.stop()
        #expect(engine.conversations[Self.sessionID] == nil)
    }

    @Test func replicaMutationRebuildsInput() async throws {
        let engine = AgentSyncEngine(transport: FixtureSyncTransport())
        var inputs: [TranscriptProjectionInput] = []
        let driver = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { input in
            inputs.append(input)
        }
        driver.start()

        let conversation = try #require(engine.conversations[Self.sessionID])
        conversation.mergePage(
            journal: Self.journalID,
            entries: [Self.entry(seq: 1)],
            windowStart: EntrySeq(rawValue: 1),
            windowEnd: EntrySeq(rawValue: 1),
            tailSeq: EntrySeq(rawValue: 1),
            hasMoreBefore: false
        )

        let observed = await Self.waitUntil {
            inputs.last?.entries.map(\.seq.rawValue) == [1]
        }
        #expect(observed)
        driver.stop()
    }

    @Test func loadOlderHasMoreBeforeChangeRebuildsInput() async throws {
        let transport = FixtureSyncTransport()
        let pageData = try JSONEncoder().encode(GuiEntriesResult(
            journalID: Self.journalID,
            entries: [Self.entry(seq: 1)],
            windowStart: EntrySeq(rawValue: 1),
            windowEnd: EntrySeq(rawValue: 1),
            tailSeq: EntrySeq(rawValue: 1),
            hasMoreBefore: true
        ))
        await transport.setHandler(method: GuiWireMethod.entries) { _ in
            pageData
        }
        let engine = AgentSyncEngine(transport: transport)
        var inputs: [TranscriptProjectionInput] = []
        let driver = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { input in
            inputs.append(input)
        }
        driver.start()

        try await engine.loadOlder(sessionID: Self.sessionID)

        let observed = await Self.waitUntil {
            inputs.last?.hasMoreBefore == true
        }
        #expect(observed)
        driver.stop()
    }

    private static let sessionID = AgentSessionID(rawValue: "session-1")
    private static let journalID = JournalID(rawValue: "journal-1")

    private static func entry(seq: Int) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journalID,
            seq: EntrySeq(rawValue: seq),
            kind: .agentProse,
            content: EntryContent(
                contentHash: seq,
                payload: .agentProse(AgentProsePayload(markdown: "entry \(seq)"))
            ),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
