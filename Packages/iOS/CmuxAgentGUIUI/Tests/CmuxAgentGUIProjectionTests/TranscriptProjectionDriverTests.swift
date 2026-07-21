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
                && inputs.last?.hasCompletedInitialSync == true
        }
        #expect(observed)
        driver.stop()
    }

    @Test func emptyProjectionBecomesEligibleOnlyAfterJournalIsKnown() async throws {
        let engine = AgentSyncEngine(transport: FixtureSyncTransport())
        var inputs: [TranscriptProjectionInput] = []
        let driver = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { input in
            inputs.append(input)
        }
        driver.start()
        #expect(inputs.last?.hasCompletedInitialSync == false)

        let conversation = try #require(engine.conversations[Self.sessionID])
        conversation.mergePage(
            journal: Self.journalID,
            entries: [],
            windowStart: EntrySeq(rawValue: 0),
            windowEnd: EntrySeq(rawValue: 0),
            tailSeq: EntrySeq(rawValue: 0),
            hasMoreBefore: false
        )

        #expect(await Self.waitUntil {
            inputs.last?.hasCompletedInitialSync == true
        })
        driver.stop()
    }

    @Test func pagingBoundaryChangeRebuildsInput() async throws {
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
            tailSeq: EntrySeq(rawValue: 2),
            hasMoreBefore: true,
            hasMoreAfter: true,
            startCursor: JournalCursor(rawValue: "before-page"),
            endCursor: JournalCursor(rawValue: "after-page")
        )

        let observed = await Self.waitUntil {
            inputs.last?.hasMoreBefore == true
                && inputs.last?.hasMoreAfter == true
                && inputs.last?.startCursor == JournalCursor(rawValue: "before-page")
                && inputs.last?.endCursor == JournalCursor(rawValue: "after-page")
        }
        #expect(observed)
        driver.stop()
    }

    @Test func sessionPhaseMutationRebuildsInput() async {
        let engine = AgentSyncEngine(transport: FixtureSyncTransport())
        engine.directory.apply(.sessionUpserted(Self.session(phase: .idle, version: 1)), origin: .live)
        var inputs: [TranscriptProjectionInput] = []
        let driver = TranscriptProjectionDriver(engine: engine, sessionID: Self.sessionID) { input in
            inputs.append(input)
        }
        driver.start()
        #expect(inputs.last?.sessionPhase == .idle)

        engine.directory.apply(.sessionUpserted(Self.session(phase: .working, version: 2)), origin: .live)

        let observed = await Self.waitUntil {
            inputs.last?.sessionPhase == .working
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

    private static func session(phase: SessionPhase, version: UInt64) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: sessionID,
            macDeviceID: MacDeviceID(rawValue: "mac-1"),
            kind: .codex,
            phase: phase,
            tier: .wrapped,
            surfaceID: "surface-1",
            cwd: "/repo",
            title: "Session",
            workspaceName: "Workspace",
            version: EntityVersion(rawValue: version),
            lastActivityHint: Int(version)
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
