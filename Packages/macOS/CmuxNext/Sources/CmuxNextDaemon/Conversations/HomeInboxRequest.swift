import Foundation

extension HomeInboxRequest {
    /// One row, already in list order (pinned rows by position, then newest activity first).
    public struct Row: Codable, Sendable, Equatable {
        public var id: String
        /// `chief`, `direct`, `channel` or `group`.
        public var kind: String
        /// A Chief row's registry name, else the title, else the other participants' names.
        public var name: String
        public var unread: Int
        public var activityAt: String
        public var preview: String?
        public var lastAuthor: String?
        public var chief: String?
        /// `working`, `waiting` or `idle` (a `chief` row only).
        public var chiefState: String?
        public var pinned: Bool
        public var pinPosition: UInt64?
        public var markedUnread: Bool
        /// `local` or `cloud` (absent from an owner before Cloud rows: local).
        public var owner: String?
        /// The person's Cloud mute (a local row: false).
        public var muted: Bool?
        enum CodingKeys: String, CodingKey {
            case id, kind, name, unread, preview, chief, pinned, owner, muted
            case activityAt = "activity_at"
            case lastAuthor = "last_author"
            case chiefState = "chief_state"
            case pinPosition = "pin_position"
            case markedUnread = "marked_unread"
        }
    }
    public struct Response: Codable, Sendable, Equatable {
        public var me: String
        public var rows: [Row]
        /// The Cloud rows: `included`, `signed_out`, `unavailable` or `not_asked`.
        public var cloud: String?
    }
}

/// `cloud-inbox-op`: `conversation-inbox-op`'s pin and mark for a Cloud conversation, forwarded to the
/// person's Cloud inbox with an idempotency key; the change comes back as `cloud-inbox-changed`.
public struct CloudInboxOpRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {}
    public static let command = "cloud-inbox-op"
    public static let requiredCapability: String? = DaemonCapability.conversationInboxState.rawValue
    public var conversation: String
    public var idempotencyKey: String
    public var op: ConversationInboxOpRequest.Op
    enum CodingKeys: String, CodingKey {
        case conversation, op
        case idempotencyKey = "idempotency_key"
    }
    /// A nil key is a new one.
    public init(conversation: String, idempotencyKey: String? = nil, op: ConversationInboxOpRequest.Op) {
        self.conversation = conversation
        self.idempotencyKey = idempotencyKey ?? UUID().uuidString.lowercased()
        self.op = op
    }
}

extension ConversationInboxOpRequest {
    public struct Op: Encodable, Sendable, Equatable {
        public var kind: String
        public var pinned: Bool?
        public var position: UInt64?
        public var unread: Bool?
        public var muted: Bool?
        /// Unix ms the mute ends; nil mutes until unmuted.
        public var until: UInt64?

        /// `inbox.pin`; a pin without `position` goes after the caller's last pin.
        public static func pin(_ pinned: Bool, position: UInt64? = nil) -> Op {
            Op(kind: "inbox.pin", pinned: pinned, position: pinned ? position : nil, unread: nil)
        }

        /// `inbox.mark_unread`.
        public static func markUnread(_ unread: Bool) -> Op { Op(kind: "inbox.mark_unread", pinned: nil, position: nil, unread: unread) }

        /// `inbox.mute` (Cloud rows only: `cloud-inbox-op`): Hide Alerts, until `until` when set.
        public static func mute(_ muted: Bool, until: UInt64? = nil) -> Op {
            Op(kind: "inbox.mute", pinned: nil, position: nil, unread: nil, muted: muted, until: muted ? until : nil)
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var conversation: String
        public var pinned: Bool
        public var markedUnread: Bool
        enum CodingKeys: String, CodingKey {
            case conversation, pinned
            case markedUnread = "marked_unread"
        }
    }
}
