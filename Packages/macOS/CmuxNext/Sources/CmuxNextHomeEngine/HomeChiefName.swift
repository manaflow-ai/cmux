public import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// The chief conversation's name (N1: "Chief"): the title a new chief
/// conversation gets, and the one-time rename of a chief conversation that
/// still has the old default title.
public nonisolated enum HomeChiefName {
    /// The key of the one-time rename (the owner applies it once).
    static let renameKey = "home-chief-title-v1"
    /// The idempotency key of the chief conversation's creation.
    static let createKey = "home-chief"

    /// The create request of a new chief conversation.
    public static func createRequest(user: ConversationParticipant, mux: ConversationParticipant) -> CreateConversationRequest {
        CreateConversationRequest(idempotencyKey: createKey, title: HomeStrings.chiefName, participants: [user, mux])
    }

    /// The name of another Chief: the Chief's own name while no Chief has it, else the first free
    /// "Chief 2", "Chief 3", … (`taken`: the names Chiefs have now). Two Chiefs never share a name:
    /// their rows could not be told apart, and `cmux chief` could not pick one of them by name.
    /// Rust's `chief_settings.nextName`.
    public static func next(taken: some Collection<String>) -> String {
        (try? HomeRules.call("chief_settings.nextName", TakenRequest(taken: Array(taken)))) ?? HomeStrings.chiefName
    }

    /// The rename of `summary` to the chief name, or nil when none is due.
    /// Only the old default titles ("Home", localized or not, or none) are
    /// renamed; a title the user chose stays. Rust's `chief_settings.titleMigration` decides.
    public static func migration(for summary: CmuxNextDaemon.ConversationSummary) -> ConversationOpRequest? {
        do {
            let due: JSONValue? = try HomeRules.call("chief_settings.titleMigration", SummaryRequest(summary: .init(summary)))
            guard due != nil else { return nil }
        } catch {
            return nil
        }
        return ConversationOpRequest(conversation: summary.id, idempotencyKey: renameKey, transaction: nil, op: .setTitle(HomeStrings.chiefName))
    }

    /// The chief conversation among `conversations`, by the rule the mux host
    /// shares (select_chief_conversation): the oldest conversation with
    /// agent_mux, by created_at, then id. List order never decides it.
    /// Rust's `chief_settings.selectChief`.
    public static func select(from conversations: [CmuxNextDaemon.ConversationSummary]) -> CmuxNextDaemon.ConversationSummary? {
        do {
            let id: String? = try HomeRules.call("chief_settings.selectChief",
                                                 ConversationsRequest(conversations: conversations.map(Summary.init)))
            return id.flatMap { id in conversations.first { $0.id == id } }
        } catch {
            return nil
        }
    }

    private nonisolated struct Summary: Encodable {
        var id: String
        var title: String
        var participants: [String]
        var createdAt: String

        init(_ summary: CmuxNextDaemon.ConversationSummary) {
            id = summary.id
            title = summary.title
            participants = summary.participants.map(\.id)
            createdAt = summary.createdAt
        }
    }

    private nonisolated struct TakenRequest: Encodable {
        var taken: [String]
        var strings = HomeChiefRuleStrings()
    }

    private nonisolated struct SummaryRequest: Encodable {
        var summary: Summary
        var strings = HomeChiefRuleStrings()
    }

    private nonisolated struct ConversationsRequest: Encodable {
        var conversations: [Summary]
    }

    /// The chief conversation on `client`'s owner: the one ``select(from:)`` picks in `listed` (the
    /// owner's list the caller just read; a second read held a fresh launch's Home a round trip
    /// longer), else one created under ``createKey``. Its one-time rename (``migration(for:)``) runs
    /// beside it, never waited for: the Chief tab and the page need only the id (CMUX-571); a failed
    /// one keeps the old title (`renameFailed`). Off the caller's actor, so `mark`, the launch marks
    /// `chief_found`, `chief_renamed`, `chief_create_sent` and `chief_create_replied`, time the owner's
    /// replies and not the caller's wait to resume.
    @concurrent public static func conversation(_ client: ConversationClient, listed: [CmuxNextDaemon.ConversationSummary],
                                                user: ConversationParticipant, mux: ConversationParticipant,
                                                mark: @escaping @Sendable (String) -> Void,
                                                renameFailed: @escaping @Sendable (any Error) -> Void) async throws -> String {
        if let existing = select(from: listed) {
            if let rename = migration(for: existing) {
                // task-owner: one rename op; ends with its reply
                Task {
                    do { _ = try await client.op(rename); mark("chief_renamed") } catch { renameFailed(error) }
                }
            }
            mark("chief_found")
            return existing.id
        }
        mark("chief_create_sent")
        let id = try await client.create(createRequest(user: user, mux: mux)).conversation.id
        mark("chief_create_replied")
        return id
    }

    /// The local user's name in the chief create request; the mux host gets
    /// the same name (MUX_USER_NAME) so both create requests are equal.
    public static var localUserName: String {
        NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }

    /// The local mux participant's id.
    static let muxID = "agent_mux"
}
