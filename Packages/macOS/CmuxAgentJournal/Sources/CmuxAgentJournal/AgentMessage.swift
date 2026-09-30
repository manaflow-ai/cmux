public import Foundation

/// Delivery state of one agent message. A message only moves forward through
/// these states: queued, then delivered, then read.
public enum AgentMessageDeliveryState: String, Codable, Sendable, CaseIterable {
    /// Stored by cmux and not yet handed to the recipient agent.
    case queued
    /// Handed to the recipient agent through one of its hooks.
    case delivered
    /// The recipient finished a turn after delivery, or a human opened it.
    case read

    fileprivate var rank: Int {
        switch self {
        case .queued: return 0
        case .delivered: return 1
        case .read: return 2
        }
    }

    /// True when moving from `self` to `next` goes forward.
    public func canAdvance(to next: AgentMessageDeliveryState) -> Bool {
        next.rank > rank
    }
}

/// One message from an agent (or a person) to the agent running in a cmux
/// surface. Messages reach the recipient through its agent hooks, never through
/// the terminal's keystroke stream, so they cannot land in a human's draft.
///
/// `senderName` and `body` are chosen by the sender and are untrusted. The
/// sender surface and workspace are recorded by cmux from the sending CLI's
/// environment and are kept separate so UIs can tell the two apart.
public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Groups a conversation. A new message starts its own thread; a reply
    /// inherits the thread of the message it answers.
    public let threadId: String
    public let senderName: String
    public let senderSurfaceId: String?
    public let senderWorkspaceId: String?
    public let recipientSurfaceId: String
    public let recipientWorkspaceId: String?
    public let body: String
    public let createdAt: Date
    public let inReplyTo: String?
    public internal(set) var state: AgentMessageDeliveryState
    public internal(set) var deliveredAt: Date?
    /// Which delivery path handed the message over, for example
    /// `claude.wake` or `codex.prompt-submit`.
    public internal(set) var deliveredVia: String?
    public internal(set) var readAt: Date?

    public init(
        id: String,
        threadId: String,
        senderName: String,
        senderSurfaceId: String?,
        senderWorkspaceId: String?,
        recipientSurfaceId: String,
        recipientWorkspaceId: String?,
        body: String,
        createdAt: Date,
        inReplyTo: String?,
        state: AgentMessageDeliveryState = .queued,
        deliveredAt: Date? = nil,
        deliveredVia: String? = nil,
        readAt: Date? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.senderName = senderName
        self.senderSurfaceId = senderSurfaceId
        self.senderWorkspaceId = senderWorkspaceId
        self.recipientSurfaceId = recipientSurfaceId
        self.recipientWorkspaceId = recipientWorkspaceId
        self.body = body
        self.createdAt = createdAt
        self.inReplyTo = inReplyTo
        self.state = state
        self.deliveredAt = deliveredAt
        self.deliveredVia = deliveredVia
        self.readAt = readAt
    }
}

/// What a sender supplies; the store assigns ids and timestamps.
public struct AgentMessageDraft: Sendable, Equatable {
    public var senderName: String
    public var senderSurfaceId: String?
    public var senderWorkspaceId: String?
    public var recipientSurfaceId: String
    public var recipientWorkspaceId: String?
    public var body: String
    public var threadId: String?
    public var inReplyTo: String?

    public init(
        senderName: String,
        senderSurfaceId: String? = nil,
        senderWorkspaceId: String? = nil,
        recipientSurfaceId: String,
        recipientWorkspaceId: String? = nil,
        body: String,
        threadId: String? = nil,
        inReplyTo: String? = nil
    ) {
        self.senderName = senderName
        self.senderSurfaceId = senderSurfaceId
        self.senderWorkspaceId = senderWorkspaceId
        self.recipientSurfaceId = recipientSurfaceId
        self.recipientWorkspaceId = recipientWorkspaceId
        self.body = body
        self.threadId = threadId
        self.inReplyTo = inReplyTo
    }
}

/// Why a draft was not accepted into the store.
public enum AgentMessageValidationError: Error, Equatable, Sendable {
    case emptyBody
    case bodyTooLarge(limit: Int)
    /// The body holds a control character other than newline or tab. These
    /// are rejected at append so no delivery path can carry escape sequences.
    case controlCharacterInBody
    case invalidSenderName
    case missingRecipient
}

extension AgentMessageDraft {
    /// Largest accepted body, in UTF-8 bytes.
    public static let maximumBodyBytes = 32 * 1024
    /// Longest accepted sender name, in characters.
    public static let maximumSenderNameLength = 64
    /// Sender name used when the caller gives none.
    public static let defaultSenderName = "agent"

    /// Returns the draft with its sender name trimmed and defaulted, or throws
    /// when it cannot be stored.
    public func validated() throws -> AgentMessageDraft {
        var draft = self
        guard !draft.recipientSurfaceId.isEmpty else {
            throw AgentMessageValidationError.missingRecipient
        }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentMessageValidationError.emptyBody
        }
        guard draft.body.utf8.count <= Self.maximumBodyBytes else {
            throw AgentMessageValidationError.bodyTooLarge(limit: Self.maximumBodyBytes)
        }
        guard !Self.containsForbiddenControlCharacter(draft.body, allowLineBreaks: true) else {
            throw AgentMessageValidationError.controlCharacterInBody
        }
        let name = draft.senderName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            draft.senderName = Self.defaultSenderName
        } else {
            guard name.count <= Self.maximumSenderNameLength,
                  !Self.containsForbiddenControlCharacter(name, allowLineBreaks: false) else {
                throw AgentMessageValidationError.invalidSenderName
            }
            draft.senderName = name
        }
        return draft
    }

    /// True when `text` holds a C0 control (other than newline and tab when
    /// `allowLineBreaks`), DEL, or a C1 control.
    static func containsForbiddenControlCharacter(_ text: String, allowLineBreaks: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0A, 0x09:
                return !allowLineBreaks
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                return true
            default:
                return false
            }
        }
    }
}
