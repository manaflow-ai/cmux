public import CmuxHomeCore
public import Foundation

/// One message request as Home shows it (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3):
/// someone the user is not connected to invited them into a DM or a group. It carries names
/// and text only; `conversation` is the one id, never shown.
public struct HomeMessageRequest: Hashable, Sendable, Identifiable {
    public var conversation: ConversationID
    /// The inviter's display name.
    public var inviter: String
    public var isGroup: Bool
    /// A group's title, when it has one.
    public var title: String?
    /// The inviter's newest message, or "".
    public var preview: String
    public var createdAt: Date?
    /// The inviter has the user's company email domain.
    public var trusted: Bool

    public var id: ConversationID { conversation }

    public init(conversation: ConversationID, inviter: String, isGroup: Bool, title: String?, preview: String,
                createdAt: Date?, trusted: Bool) {
        self.conversation = conversation
        self.inviter = inviter
        self.isGroup = isGroup
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.trusted = trusted
    }
}
