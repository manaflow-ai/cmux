import Foundation

/// How a message reaches a recipient: Messages' blue iMessage or green SMS.
public enum ConversationService: String, Sendable, Hashable {
    case iMessage
    case sms = "SMS"
}

/// One address of a contact, as the recipient autocomplete lists it.
public struct ConversationContactHandle: Sendable, Hashable {
    /// As displayed: `+1 (555) 564-8583`, `kate-bell@mac.com`.
    public var value: String
    /// `mobile`, `home`, `work`, `iPhone`.
    public var label: String
    public var service: ConversationService

    public init(value: String, label: String, service: ConversationService) {
        self.value = value
        self.label = label
        self.service = service
    }
}

/// A person New Message can address.
public struct ConversationContact: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var initials: String
    public var colorHex: String
    public var handles: [ConversationContactHandle]

    public init(id: String, name: String, initials: String, colorHex: String, handles: [ConversationContactHandle]) {
        self.id = id
        self.name = name
        self.initials = initials
        self.colorHex = colorHex
        self.handles = handles
    }

    /// The service a message to this contact uses: iMessage when any handle has it.
    public var service: ConversationService {
        handles.contains { $0.service == .iMessage } ? .iMessage : .sms
    }
}

/// The availability of a typed address.
public struct ConversationHandleLookup: Sendable, Hashable {
    public var handle: String
    /// Nil when the text is not a valid address.
    public var service: ConversationService?
    /// The contact that owns the address, when known.
    public var contact: ConversationContact?

    public init(handle: String, service: ConversationService?, contact: ConversationContact?) {
        self.handle = handle
        self.service = service
        self.contact = contact
    }
}

/// A recipient as `createConversation` takes it.
public enum ConversationRecipientRef: Sendable, Hashable {
    case participant(String)
    case handle(String)
}

/// The conversation New Message opens.
public struct ConversationCreation: Sendable, Hashable {
    public var info: ConversationInfo
    /// False when a conversation with exactly these recipients already existed.
    public var created: Bool
    public var service: ConversationService

    public init(info: ConversationInfo, created: Bool, service: ConversationService) {
        self.info = info
        self.created = created
        self.service = service
    }
}

/// Contacts and conversation creation behind New Message. Separate from
/// `ConversationBackend` (which is one conversation's session) so a backend
/// without a directory needs no changes.
public protocol ConversationDirectory: AnyObject, Sendable {
    /// Recipient autocomplete; `excluding` holds contact ids already added.
    /// A blank query lists every contact (the + Add Contact picker).
    func searchContacts(_ query: String, limit: Int, excluding: [String]) async throws -> [ConversationContact]
    /// iMessage/SMS availability of typed addresses, in order.
    func lookupHandles(_ handles: [String]) async throws -> [ConversationHandleLookup]
    /// Opens the conversation with exactly these recipients, creating it if needed.
    func createConversation(_ recipients: [ConversationRecipientRef]) async throws -> ConversationCreation
}
