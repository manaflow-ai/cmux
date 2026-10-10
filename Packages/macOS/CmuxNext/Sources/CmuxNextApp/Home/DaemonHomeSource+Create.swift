import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension DaemonHomeSource {
    /// The local Chief: every local conversation has it (`HomeService.mux`).
    static let chief = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief", agentClass: "mux", acpSession: "mux")

    /// `createGroup` on the local owner: a channel of the local user and the
    /// named local participants (the Chief when none is named). A name the
    /// local owner never listed is refused (`unknown_participant`); people
    /// on other accounts belong to a cloud group. The intent's key makes a
    /// resend open the same channel. The new channel reaches every
    /// subscriber as a fresh inbox.
    func createChannel(title: String, participants ids: [ParticipantID], key: IdempotencyKey) async throws -> HomeOpResult {
        let connection = try requireOwner()
        let client = ConversationClient(connection)
        let listed = try await Self.mapped { try await client.list() }
        var known: [String: ConversationParticipant] = [Self.chief.id: Self.chief]
        for summary in listed {
            for participant in summary.participants where known[participant.id] == nil { known[participant.id] = participant }
        }
        let user = known[me.id.rawValue] ?? ConversationParticipant(id: me.id.rawValue, kind: .human, displayName: me.displayName)
        var members = [user]
        for id in ids.isEmpty ? [ParticipantID(Self.chief.id)] : ids where id != me.id && !members.contains(where: { $0.id == id.rawValue }) {
            guard let participant = known[id.rawValue] else { throw HomeRejection.invalid("unknown_participant") }
            members.append(participant)
        }
        let request = CreateConversationRequest(idempotencyKey: key.rawValue, title: title, participants: members)
        let created = try await Self.mapped { try await client.create(request) }
        if let inbox = try? await inbox() { publish(.inbox(inbox)) }
        return HomeOpResult(rev: 0, replayed: created.replayed, conversation: ConversationID(created.conversation.id))
    }

    /// My own send reads the conversation through it (the mock owner's
    /// rule), so `unreadCount(me:)` never counts my messages. Best effort:
    /// the owner refuses a cursor that would move back, which is fine.
    func readThrough(_ seq: Seq, in conversation: String, on connection: DaemonConnection) {
        let request = ConversationOpRequest(conversation: conversation, idempotencyKey: "read:\(me.id.rawValue):\(seq)",
                                            transaction: nil, op: .setReadCursor(seq: seq))
        // task-owner: one read_cursor.set write; ends with its reply
        Task { _ = try? await ConversationClient(connection).op(request) }
    }
}
