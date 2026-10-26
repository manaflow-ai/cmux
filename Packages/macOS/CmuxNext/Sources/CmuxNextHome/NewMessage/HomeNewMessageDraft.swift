public import CmuxHomeCore
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
    public var recipients: [HomeRecipient] { tokens.compactMap(\.recipient) }
    /// Some token names nobody (it draws red; the send waits).
    public var hasInvalidTokens: Bool { tokens.contains { !$0.isValid } }
    /// Nothing chosen and nothing typed in the To: field.
    public var isEmpty: Bool { tokens.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Several people: the first send makes a group.
    public var isGroup: Bool { recipients.count > 1 }

    /// Adds a chosen recipient as a token (once) and clears the typed text.
    public mutating func add(_ recipient: HomeRecipient) {
        query = ""
        guard !tokens.contains(where: { $0.recipient == recipient }) else { return }
        tokens.append(HomeRecipientToken(recipient))
    }

    /// Return, comma or Tab: the typed text becomes a token. It is the
    /// address it parses as, else the contact it names exactly (name or
    /// id), else the only contact whose name starts with it; otherwise an
    /// invalid (red) token. False when there was nothing to commit.
    @discardableResult
    public mutating func commit(contacts: [HomeContact]) -> Bool {
        let text = query.trimmingCharacters(in: Self.separators)
        query = ""
        guard !text.isEmpty else { return false }
        guard let recipient = Self.resolve(text, contacts: contacts) else {
            tokens.append(HomeRecipientToken(text: text, recipient: nil))
            return true
        }
        guard !tokens.contains(where: { $0.recipient == recipient }) else { return true }
        tokens.append(HomeRecipientToken(text: recipient.label, recipient: recipient))
        return true
    }

    /// Backspace with nothing typed removes the last token. False when the
    /// field had typed text (Backspace edits it) or no token.
    @discardableResult
    public mutating func deleteBackward() -> Bool {
        guard query.isEmpty, !tokens.isEmpty else { return false }
        tokens.removeLast()
        return true
    }

    /// Removes the token at `index` (its chip's delete).
    public mutating func remove(at index: Int) {
        guard tokens.indices.contains(index) else { return }
        tokens.remove(at: index)
    }

    /// Characters that end a token as the person types them.
    public static let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)

    /// The recipient `text` names: an email address or phone number, else
    /// a contact by exact id or name, else the one contact whose name
    /// starts with it. Nil when it names nobody.
    public static func resolve(_ text: String, contacts: [HomeContact]) -> HomeRecipient? {
        let text = text.trimmingCharacters(in: separators)
        guard !text.isEmpty else { return nil }
        if let address = ContactAddress.parse(text) { return .address(address) }
        if let contact = contacts.first(where: {
            $0.id.rawValue == text || $0.name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .contact(contact)
        }
        let starts = contacts.filter { $0.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        return starts.count == 1 ? .contact(starts[0]) : nil
    }

    /// The suggestions under the To: field for the typed text: a typed
    /// address first, then people whose name has a word starting with the
    /// text, then names that contain it; people already chosen are left
    /// out. Empty text suggests nobody (Messages waits for a letter).
    public func suggestions(contacts: [HomeContact], limit: Int = 8) -> [HomeRecipient] {
        let text = query.trimmingCharacters(in: Self.separators)
        guard !text.isEmpty else { return [] }
        let chosen = Set(recipients)
        var result: [HomeRecipient] = []
        if let address = ContactAddress.parse(text), !chosen.contains(.address(address)) { result.append(.address(address)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let wordStart = contacts.filter { contact in
            contact.name.split(whereSeparator: { $0.isWhitespace }).contains { $0.range(of: text, options: options.union(.anchored)) != nil }
        }
        let inside = contacts.filter { $0.name.range(of: text, options: options) != nil && !wordStart.contains($0) }
        for contact in wordStart + inside where !chosen.contains(.contact(contact)) {
            result.append(.contact(contact))
        }
        return Array(result.prefix(limit))
    }

    /// The Chiefs listed under the To: field before anything is typed
    /// (plans/cmux-next/chief-group-chats-DESIGN.md): the user's Chiefs not chosen yet, in the
    /// contacts' order, at most `limit`. Choosing one adds it as a token.
    public func chiefShortcuts(contacts: [HomeContact], limit: Int = 6) -> [HomeContact] {
        let chosen = Set(recipients)
        return Array(contacts.filter { $0.source == .agent && !chosen.contains(.contact($0)) }.prefix(limit))
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
        let chosen = Set(recipients)
        let team = contacts.filter { $0.source == .team && !chosen.contains(.contact($0)) }
        return chiefShortcuts(contacts: contacts, limit: chiefLimit) + team
    }

    /// The conversation that already has exactly the chosen people (one
    /// person: their DM or the Chief's conversation; several: a group with
    /// exactly them), newest first as the inbox lists it. Nil while a
    /// token is invalid or nobody is chosen. An address matches a person
    /// invited by that address.
    public func existingConversation(in rows: [InboxRow], me: ParticipantID?) -> ConversationID? {
        let recipients = recipients
        guard !recipients.isEmpty, !hasInvalidTokens else { return nil }
        let wanted = Set(recipients.map(Self.key))
        let match = rows.first { row in
            guard recipients.count == 1 ? row.kind != .group : row.kind == .group else { return false }
            let others = row.summary.participants.filter { $0.id != me }
            guard others.count == wanted.count else { return false }
            return Set(others.map(Self.key)) == wanted
        }
        return match?.id
    }

    /// Why the first send cannot go yet (shown under the To: field), or nil
    /// when it can: a red token first, then nobody chosen.
    public var sendBlocker: String? {
        if let invalid = tokens.first(where: { !$0.isValid }) { return HomeConversationStrings.unknownRecipient(invalid.text) }
        return recipients.isEmpty ? Self.needsRecipientNotice : nil
    }

    /// "Add someone in To: first."
    public static var needsRecipientNotice: String { HomeConversationStrings.needsRecipient }

    /// The title of the list's draft row (Messages keeps "New Message" until the first send).
    public static var rowTitle: String { HomeConversationStrings.composeTitle }

    /// A participant's matching key: an invited address's text, else its id.
    private static func key(_ participant: Participant) -> String {
        if participant.membership == .invited, let contact = participant.invitedContact,
           let address = ContactAddress.parse(contact) {
            return "address:" + address.description
        }
        return "id:" + participant.id.rawValue
    }

    private static func key(_ recipient: HomeRecipient) -> String {
        switch recipient {
        case .contact(let contact): "id:" + contact.id.rawValue
        case .address(let address): "address:" + address.description
        }
    }
}
