public import CmuxHomeCore
public import CmuxNextHomeModel
public import Foundation

/// New Message as Messages has it (Lawrence 2026-10-19: no modal, a page):
/// the To: field's tokens and the text being typed into it, with the rules
/// for turning text into tokens, the suggestions under the field, and the
/// existing conversation the chosen people already have. A value type, so
/// the page and its tests share one source of truth.
///
/// ```swift
/// var draft = HomeNewMessageDraft()
/// draft.query = "ada"
/// draft.commit(contacts: contacts)          // "Ada" becomes a token
/// draft.existingConversation(in: rows, me: me) // her DM, when there is one
/// ```
public struct HomeNewMessageDraft: Hashable, Sendable {
    /// The To: field's tokens, in the order they were added.
    public private(set) var tokens: [HomeRecipientToken] = []
    /// The text typed after the last token (not a token yet).
    public var query = ""

    /// Creates an empty draft.
    public init() {}

    /// The recipients of the valid tokens, in order.
    public var recipients: [HomeRecipient] { state.homeRecipients }
    /// Some token names nobody (it draws red; the send waits).
    public var hasInvalidTokens: Bool { state.hasInvalidTokens }
    /// Nothing chosen and nothing typed in the To: field.
    public var isEmpty: Bool { state.isEmpty }
    /// Several people: the first send makes a group.
    public var isGroup: Bool { state.isGroup }

    /// Adds a chosen recipient as a token (once) and clears the typed text.
    public mutating func add(_ recipient: HomeRecipient) {
        apply("draft.add", .init(draft: rules, recipient: recipient))
    }

    /// Return, comma or Tab: the typed text becomes a token. It is the
    /// address it parses as, else the contact it names exactly (name or
    /// id), else the only contact whose name starts with it; otherwise an
    /// invalid (red) token. False when there was nothing to commit.
    @discardableResult
    public mutating func commit(contacts: [HomeContact]) -> Bool {
        apply("draft.commit", .init(draft: rules, contacts: contacts))
    }

    /// Backspace with nothing typed removes the last token. False when the
    /// field had typed text (Backspace edits it) or no token.
    @discardableResult
    public mutating func deleteBackward() -> Bool {
        apply("draft.deleteBackward", .init(draft: rules))
    }

    /// Removes the token at `index` (its chip's delete).
    public mutating func remove(at index: Int) {
        guard index >= 0 else { return }
        apply("draft.remove", .init(draft: rules, index: index))
    }

    /// Characters that end a token as the person types them.
    public static let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)

    /// The recipient `text` names: an email address or phone number, else
    /// a contact by exact id or name, else the one contact whose name
    /// starts with it. Nil when it names nobody.
    public static func resolve(_ text: String, contacts: [HomeContact]) -> HomeRecipient? {
        let found: HomeComposeRules.Recipient? = HomeComposeRules.call(
            "draft.resolve", HomeComposeRules.ResolveRequest(text: text, contacts: contacts), fallback: nil)
        return found?.recipient
    }

    /// The suggestions under the To: field for the typed text: a typed
    /// address first, then people whose name has a word starting with the
    /// text, then names that contain it; people already chosen are left
    /// out. Empty text suggests nobody (Messages waits for a letter).
    public func suggestions(contacts: [HomeContact], limit: Int = 8) -> [HomeRecipient] {
        let found: [HomeComposeRules.Recipient] = HomeComposeRules.call(
            "draft.suggestions", HomeComposeRules.DraftRequest(draft: rules, contacts: contacts, limit: limit), fallback: [])
        return found.compactMap(\.recipient)
    }

    /// The Chiefs listed under the To: field before anything is typed
    /// (plans/cmux-next/chief-group-chats-DESIGN.md): the user's Chiefs not chosen yet, in the
    /// contacts' order, at most `limit`. Choosing one adds it as a token.
    public func chiefShortcuts(contacts: [HomeContact], limit: Int = 6) -> [HomeContact] {
        let found: [HomeComposeRules.Contact] = HomeComposeRules.call(
            "draft.chiefShortcuts", HomeComposeRules.DraftRequest(draft: rules, contacts: contacts, limit: limit), fallback: [])
        return found.map(\.contact)
    }

    /// The people listed under the To: field before anything is typed: the Chiefs
    /// (``chiefShortcuts(contacts:limit:)``), then every team member not chosen yet, in the
    /// contacts' order (the user, 2026-10-21: everyone on the team is someone to chat to).
    ///
    /// - Parameters:
    ///   - contacts: Everyone New Message offers (``HomeContact/merged(team:connections:agents:)``).
    ///   - chiefLimit: At most this many Chiefs lead the list.
    /// - Returns: The Chiefs, then the team members, none already a token.
    public func idleSuggestions(contacts: [HomeContact], chiefLimit: Int = 6) -> [HomeContact] {
        let found: [HomeComposeRules.Contact] = HomeComposeRules.call(
            "draft.idleSuggestions", HomeComposeRules.DraftRequest(draft: rules, contacts: contacts, limit: chiefLimit), fallback: [])
        return found.map(\.contact)
    }

    /// The conversation that already has exactly the chosen people (one
    /// person: their DM or the Chief's conversation; several: a group with
    /// exactly them), newest first as the inbox lists it. Nil while a
    /// token is invalid or nobody is chosen. An address matches a person
    /// invited by that address.
    public func existingConversation(in rows: [InboxRow], me: ParticipantID?) -> ConversationID? {
        guard !tokens.isEmpty else { return nil }
        let found: String? = HomeComposeRules.call(
            "draft.existingConversation", HomeComposeRules.DraftRequest(draft: rules, rows: rows, me: me), fallback: nil)
        return found.map(ConversationID.init)
    }

    /// Why the first send cannot go yet (shown under the To: field), or nil
    /// when it can: a red token first, then nobody chosen.
    public var sendBlocker: String? {
        guard let blocker = state.sendBlocker else { return nil }
        if blocker.kind == "unknownRecipient" { return HomeConversationStrings.unknownRecipient(blocker.text ?? "") }
        return Self.needsRecipientNotice
    }

    /// "Add someone in To: first."
    public static var needsRecipientNotice: String { HomeConversationStrings.needsRecipient }

    /// The title of the list's draft row (Messages keeps "New Message" until the first send).
    public static var rowTitle: String { HomeConversationStrings.composeTitle }

    /// The draft as the rules read it.
    private var rules: HomeComposeRules.Draft {
        HomeComposeRules.Draft(tokens: tokens.map { HomeComposeRules.Token(text: $0.text, recipient: $0.recipient) }, query: query)
    }

    /// `draft.state`: the recipients, the red tokens, emptiness and the send's blocker.
    private var state: HomeComposeRules.DraftState {
        HomeComposeRules.call("draft.state", HomeComposeRules.DraftRequest(draft: rules), fallback: .empty)
    }

    /// Runs a draft op and takes the draft it returns; true when it changed.
    @discardableResult
    private mutating func apply(_ op: String, _ request: HomeComposeRules.DraftRequest) -> Bool {
        let reply: HomeComposeRules.Changed? = HomeComposeRules.call(op, request, fallback: nil)
        guard let reply else { return false }
        tokens = reply.draft.tokens.map { HomeRecipientToken(text: $0.text, recipient: $0.homeRecipient) }
        query = reply.draft.query
        return reply.changed
    }
}
