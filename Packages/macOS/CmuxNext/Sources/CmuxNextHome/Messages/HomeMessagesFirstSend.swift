public import CmuxHomeCore
public import CmuxNextHomeModel
public import CmuxNextSettings
import Foundation

/// New Message's first send on the Messages page (`cmux.home.messages.start {recipients, text}`), as
/// the native New Message sent it (HomeNewMessageView.firstSend): makes the DM or group with the
/// recipients (`start`, HomeService.startConversation) and posts the text there through HomeStore
/// (addresses only: the email-link start carries the text). What the native transcript then showed
/// of that send, the page shows too:
/// - refused by the owner: nothing went, so it leaves HomeStore's log and the answer is the refusal
///   (`refusal`, HomeComposer's words): New Message stays with its people, the text back in its box
///   and the reason under To: (NewMessage.tsx);
/// - no answer (offline, lost, given up): the conversation opens with the send as the page keeps one
///   (`pending`, HomeMessagesOutbox.row: Not Delivered, Retry under its own key, so it never goes
///   twice). The host's outbox keeps it before it leaves the log, so the handoff to the page never
///   holds it only in flight. It leaves the log unless it is in flight there (then the owner's echo
///   settles the page's row, and a later failure moves over at the next outbox load).
///
/// The conversation is selected (`select`, HomeService.pendingSelection) only once the send's
/// outcome is known, and only when it opened: a selection published before would let the page's
/// selection watch open the conversation and leave New Message while the send could still be refused.
@MainActor
public struct HomeMessagesFirstSend {
    private let store: HomeStore
    private let contacts: [HomeContact]
    private let start: @MainActor ([HomeRecipient], [MessagePart]) async -> HomeComposeOutcome
    private let refusal: @MainActor (any Error, String) -> HomeComposeOutcome
    private let select: @MainActor (ConversationID) -> Void

    /// `start` makes the conversation without selecting it; `select` selects it once the outcome is known.
    public init(store: HomeStore, contacts: [HomeContact],
                start: @escaping @MainActor (_ recipients: [HomeRecipient], _ firstMessage: [MessagePart]) async -> HomeComposeOutcome,
                refusal: @escaping @MainActor (_ error: any Error, _ naming: String) -> HomeComposeOutcome,
                select: @escaping @MainActor (_ conversation: ConversationID) -> Void = { _ in }) {
        self.store = store
        self.contacts = contacts
        self.start = start
        self.refusal = refusal
        self.select = select
    }

    /// `{outcome}` (HomeComposeOutcome.pageOutcome); an opened one may carry `pending: [row]`. `key`: the send's.
    public func run(_ fields: [String: JSONValue], key: IdempotencyKey = .make()) async -> JSONValue {
        let answer = await outcome(fields, key: key)
        if answer.value(at: ["outcome", "kind"]) == .string("opened"),
           let id = answer.value(at: ["outcome", "conversation"])?.stringValue {
            select(ConversationID(id))
        }
        return answer
    }

    private func outcome(_ fields: [String: JSONValue], key: IdempotencyKey) async -> JSONValue {
        let recipients = Self.recipients(fields["recipients"]?.arrayValue ?? [], contacts: contacts)
        guard !recipients.isEmpty else { return HomeComposeOutcome.refused("").pageOutcome }
        let text = (fields["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [MessagePart] = text.isEmpty ? [] : [.text(text)]
        let addressesOnly = recipients.allSatisfy { if case .address = $0 { true } else { false } }
        let outcome = await start(recipients, addressesOnly ? parts : [])
        guard case .opened(let id) = outcome, !addressesOnly, !parts.isEmpty else { return outcome.pageOutcome }
        do {
            _ = try await store.perform(.sendMessage(conversation: id, parts: parts), key: key)
            return outcome.pageOutcome
        } catch is HomeSendState {
            guard let send = store.cachedSend(key) else { return outcome.pageOutcome }
            let row = HomeMessagesOutbox.row(send)
            // The outbox keeps it first, in the same cache as HomeStore's log (one snapshot writes
            // both): only then does it leave the native queue, so a lost answer or a reload of the
            // page before it puts the row itself never loses it. One the outbox refuses (past its
            // cap) stays in the queue, which still sends it; the page's row says it is not kept.
            if (try? HomeMessagesOutbox(store: store).put(row, for: send.conversation)) != nil { store.cancelSend(key) }
            return .object(["outcome": .object(["kind": .string("opened"), "conversation": .string(id.rawValue),
                                                "pending": .array([row])])])
        } catch {
            store.discardFailed(key)
            let naming = recipients.map(\.label).joined(separator: ", ")
            return refusal(error, naming).pageOutcome
        }
    }

    /// The page's recipients: a contact by id (one New Message no longer lists keeps its id), or an address.
    static func recipients(_ entries: [JSONValue], contacts: [HomeContact]) -> [HomeRecipient] {
        entries.compactMap { entry in
            if let id = entry["contact"]?.stringValue, !id.isEmpty {
                return .contact(contacts.first { $0.id.rawValue == id } ?? HomeContact(id: ParticipantID(id), name: id, source: .team))
            }
            return entry["address"]?.stringValue.flatMap { ContactAddress.parse($0) }.map(HomeRecipient.address)
        }
    }
}
