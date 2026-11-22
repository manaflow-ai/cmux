import CmuxNextDaemon
import Foundation

/// The chief conversation's name (N1: "Chief"): the title a new chief
/// conversation gets, and the one-time rename of a chief conversation that
/// still has the old default title.
nonisolated enum HomeChiefName {
    /// The key of the one-time rename (the owner applies it once).
    static let renameKey = "home-chief-title-v1"
    /// The idempotency key of the chief conversation's creation.
    static let createKey = "home-chief"

    /// The create request of a new chief conversation.
    static func createRequest(user: ConversationParticipant, mux: ConversationParticipant) -> CreateConversationRequest {
        CreateConversationRequest(idempotencyKey: createKey, title: HomeStrings.chiefName, participants: [user, mux])
    }

    /// The rename of `summary` to the chief name, or nil when none is due.
    /// Only the old default titles ("Home", localized or not, or none) are
    /// renamed; a title the user chose stays.
    static func migration(for summary: CmuxNextDaemon.ConversationSummary) -> ConversationOpRequest? {
        let name = HomeStrings.chiefName
        guard summary.participants.contains(where: { $0.id == muxID }), summary.title != name,
              [HomeStrings.title, "Home", ""].contains(summary.title) else { return nil }
        return ConversationOpRequest(conversation: summary.id, idempotencyKey: renameKey, transaction: nil, op: .setTitle(name))
    }

    /// The chief conversation among `conversations`, by the rule the mux host
    /// shares (select_chief_conversation): the oldest conversation with
    /// agent_mux, by created_at, then id. List order never decides it.
    static func select(from conversations: [CmuxNextDaemon.ConversationSummary]) -> CmuxNextDaemon.ConversationSummary? {
        conversations.filter { $0.participants.contains { $0.id == muxID } }.min { a, b in
            let (da, db) = (HomeCoreMapping.date(a.createdAt) ?? .distantFuture, HomeCoreMapping.date(b.createdAt) ?? .distantFuture)
            return da != db ? da < db : a.id < b.id
        }
    }

    /// The local user's name in the chief create request; the mux host gets
    /// the same name (MUX_USER_NAME) so both create requests are equal.
    static var localUserName: String {
        NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }

    /// The local mux participant's id.
    static let muxID = "agent_mux"
}
