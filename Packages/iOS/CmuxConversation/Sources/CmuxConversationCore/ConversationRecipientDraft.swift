import Foundation

/// One token in New Message's To: field.
public struct ConversationRecipient: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// A typed address whose availability is being looked up ("Searching").
        case resolving
        case resolved(ConversationService)
        /// Not a valid address; Messages draws it red and will not send.
        case invalid
    }

    /// `c:<contactID>` for a contact, `h:<address>` for a typed address.
    public let id: String
    public var name: String
    public var contactID: String?
    public var handle: String?
    public var state: State

    public init(id: String, name: String, contactID: String?, handle: String?, state: State) {
        self.id = id
        self.name = name
        self.contactID = contactID
        self.handle = handle
        self.state = state
    }

    public static func contact(_ contact: ConversationContact) -> ConversationRecipient {
        ConversationRecipient(id: "c:\(contact.id)", name: contact.name, contactID: contact.id, handle: nil, state: .resolved(contact.service))
    }

    public static func typed(_ address: String) -> ConversationRecipient {
        ConversationRecipient(id: "h:\(address.lowercased())", name: address, contactID: nil, handle: address, state: .resolving)
    }

    public var service: ConversationService? {
        if case let .resolved(service) = state { return service }
        return nil
    }

    public var ref: ConversationRecipientRef {
        contactID.map(ConversationRecipientRef.participant) ?? .handle(handle ?? name)
    }
}

/// The To: field's model, shared by iOS and macOS: tokens, the text being
/// typed after them, and Messages' token selection rules (Backspace on an
/// empty field selects the last token, a second Backspace deletes it, and a
/// selected token is removed as a unit).
public struct ConversationRecipientDraft: Sendable, Hashable {
    public private(set) var recipients: [ConversationRecipient] = []
    /// Text typed after the last token (the autocomplete query).
    public private(set) var text = ""
    public private(set) var selectedID: String?

    public init() {}

    /// The trimmed query; empty when there is nothing to search.
    public var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var contactIDs: [String] { recipients.compactMap(\.contactID) }

    /// Messages' service line under the To: field: SMS when any recipient is
    /// SMS-only, iMessage when every recipient is known to have it, nothing
    /// while there are no resolved recipients.
    public var service: ConversationService? {
        let services = recipients.compactMap(\.service)
        if services.contains(.sms) { return .sms }
        if services.isEmpty { return nil }
        return services.count == recipients.count ? .iMessage : nil
    }

    /// The first send needs at least one recipient, none still looking up,
    /// none invalid.
    public var canSend: Bool {
        !recipients.isEmpty && recipients.allSatisfy { if case .resolved = $0.state { return true } else { return false } }
    }

    /// Typing replaces the query and drops any token selection.
    public mutating func setText(_ newValue: String) {
        text = newValue
        if !newValue.isEmpty { selectedID = nil }
    }

    /// Adds a contact picked from the autocomplete (or the + contact picker).
    /// Returns false when that person is already a recipient.
    @discardableResult
    public mutating func add(_ contact: ConversationContact) -> Bool {
        text = ""
        selectedID = nil
        guard !recipients.contains(where: { $0.contactID == contact.id }) else { return false }
        recipients.append(.contact(contact))
        return true
    }

    /// Return (or a comma) turns the typed text into a token. Returns the new
    /// recipient, which starts `.resolving` until `resolve` reports back.
    @discardableResult
    public mutating func commitText() -> ConversationRecipient? {
        let address = query
        guard !address.isEmpty else { return nil }
        text = ""
        selectedID = nil
        let recipient = ConversationRecipient.typed(address)
        guard !recipients.contains(where: { $0.id == recipient.id }) else { return nil }
        recipients.append(recipient)
        return recipient
    }

    /// Applies an availability lookup to the typed token it came from. A
    /// lookup that names a contact turns the token into that contact (or
    /// drops it when the contact is already a recipient).
    public mutating func resolve(_ lookup: ConversationHandleLookup) {
        guard let index = recipients.firstIndex(where: { $0.handle?.lowercased() == lookup.handle.lowercased() && $0.state == .resolving }) else { return }
        guard let service = lookup.service else {
            recipients[index].state = .invalid
            return
        }
        if let contact = lookup.contact {
            if recipients.contains(where: { $0.contactID == contact.id }) {
                if selectedID == recipients[index].id { selectedID = nil }
                recipients.remove(at: index)
                return
            }
            recipients[index].name = contact.name
            recipients[index].contactID = contact.id
        }
        recipients[index].state = .resolved(service)
    }

    /// A tap on a token selects it; tapping the text area deselects.
    public mutating func select(_ id: String?) {
        selectedID = id.flatMap { id in recipients.contains { $0.id == id } ? id : nil }
    }

    public mutating func remove(_ id: String) {
        recipients.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    /// Backspace. Returns true when the token field consumed it (selected or
    /// removed a token); false means the text field deletes a character.
    @discardableResult
    public mutating func backspace() -> Bool {
        if let selectedID {
            remove(selectedID)
            return true
        }
        guard text.isEmpty, let last = recipients.last else { return false }
        selectedID = last.id
        return true
    }
}
