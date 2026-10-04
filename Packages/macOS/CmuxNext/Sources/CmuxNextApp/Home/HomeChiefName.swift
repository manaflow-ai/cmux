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
        CreateConversationRequest(idempotencyKey: createKey, title: HomeStrings.title, participants: [user, mux])
    }

    /// The rename of `summary` to the chief name, or nil when none is due.
    static func migration(for summary: CmuxNextDaemon.ConversationSummary) -> ConversationOpRequest? {
        nil
    }
}
