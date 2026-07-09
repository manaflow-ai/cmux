import Foundation
@testable import CmuxAgentReplica

struct ReplicaTestSupport {
    static let mac = MacDeviceID(rawValue: "mac-1")
    static let session = AgentSessionID(rawValue: "session-1")
    static let otherSession = AgentSessionID(rawValue: "session-2")
    static let journal = JournalID(rawValue: "journal-1")
    static let otherJournal = JournalID(rawValue: "journal-2")

    static func clock() -> ManualReplicaClock {
        ManualReplicaClock(currentTick: 10)
    }

    static func version(_ raw: UInt64) -> EntityVersion {
        EntityVersion(rawValue: raw)
    }

    static func seq(_ raw: Int) -> EntrySeq {
        EntrySeq(rawValue: raw)
    }

    static func snapshot(
        id: AgentSessionID = session,
        phase: SessionPhase = .idle,
        version rawVersion: UInt64 = 1,
        recency: Int = 0
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id,
            macDeviceID: mac,
            kind: .codex,
            phase: phase,
            tier: .wrapped,
            surfaceID: nil,
            cwd: "/repo",
            title: "Session \(id.rawValue)",
            workspaceName: "Workspace",
            version: version(rawVersion),
            lastActivityHint: recency
        )
    }

    static func entry(
        _ rawSeq: Int,
        journalID: JournalID = journal,
        version rawVersion: UInt64 = 1,
        hash: Int? = nil
    ) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journalID,
            seq: seq(rawSeq),
            kind: .agentProse,
            content: EntryContent(contentHash: hash ?? rawSeq),
            version: version(rawVersion)
        )
    }

    static func ticket(
        id: UUID,
        state: SendTicketState,
        createdAt: Int,
        sessionID: AgentSessionID = session
    ) -> SendTicket {
        SendTicket(
            id: id,
            sessionID: sessionID,
            text: "hello",
            attachmentCount: 0,
            state: state,
            createdAt: createdAt
        )
    }
}
