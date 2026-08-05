import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
import Foundation

enum AgentSyncTestSupport {
    static let mac = MacDeviceID(rawValue: "mac-1")
    static let session = AgentSessionID(rawValue: "session-1")
    static let otherSession = AgentSessionID(rawValue: "session-2")
    static let epochOne = ReplicaEpoch(rawValue: "epoch-1")
    static let epochTwo = ReplicaEpoch(rawValue: "epoch-2")
    static let journalOne = JournalID(rawValue: "journal-1")
    static let journalTwo = JournalID(rawValue: "journal-2")

    static func hello(epoch: ReplicaEpoch) -> GuiHelloResult {
        GuiHelloResult(
            protocol: 1,
            serverCaps: ["gui.v1.sessions", "gui.v1.journal"],
            epoch: epoch,
            macDeviceID: mac,
            serverTimeMS: 1_000
        )
    }

    static func sessionSnapshot(
        title: String = "Session",
        version: UInt64 = 1
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: session,
            macDeviceID: mac,
            kind: .codex,
            phase: .working,
            tier: .wrapped,
            surfaceID: "surface-1",
            cwd: "/repo",
            title: title,
            workspaceName: "Workspace",
            version: EntityVersion(rawValue: version),
            lastActivityHint: Int(version)
        )
    }

    static func entry(
        _ rawSequence: Int,
        journalID: JournalID = journalOne,
        version: UInt64 = 1,
        hash: Int? = nil
    ) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journalID,
            seq: EntrySeq(rawValue: rawSequence),
            kind: .agentProse,
            content: EntryContent(
                contentHash: hash ?? rawSequence,
                payload: .agentProse(AgentProsePayload(markdown: "entry \(rawSequence)"))
            ),
            version: EntityVersion(rawValue: version)
        )
    }

    static func page(
        journalID: JournalID = journalOne,
        entries: [EntrySnapshot],
        windowStart: Int? = nil,
        windowEnd: Int? = nil,
        tail: Int? = nil,
        hasMoreBefore: Bool = false,
        hasMoreAfter: Bool = false,
        startCursor: String? = nil,
        endCursor: String? = nil,
        tailCursor: String? = nil,
        requiresPagingRestart: Bool = false
    ) -> GuiEntriesResult {
        let first = windowStart ?? entries.first?.seq.rawValue ?? 0
        let last = windowEnd ?? entries.last?.seq.rawValue ?? 0
        return GuiEntriesResult(
            journalID: journalID,
            entries: entries,
            windowStart: EntrySeq(rawValue: first),
            windowEnd: EntrySeq(rawValue: last),
            tailSeq: EntrySeq(rawValue: tail ?? last),
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            startCursor: startCursor.map { JournalCursor(rawValue: $0) },
            endCursor: endCursor.map { JournalCursor(rawValue: $0) },
            tailCursor: tailCursor.map { JournalCursor(rawValue: $0) },
            requiresPagingRestart: requiresPagingRestart
        )
    }

    static func eventData(
        _ payload: GuiEventPayload,
        epoch: ReplicaEpoch = epochOne,
        sessionID: AgentSessionID = session
    ) throws -> Data {
        try JSONEncoder().encode(GuiEventFrame(epoch: epoch, sessionID: sessionID, payload: payload))
    }

    @MainActor
    static func waitUntil(
        iterations: Int = 5_000,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
