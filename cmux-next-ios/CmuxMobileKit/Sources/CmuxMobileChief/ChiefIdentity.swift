import CmuxConversationCore
import Foundation

/// Who is in the Chief conversation. Ids follow the Mac's Chief owner:
/// `user_local` for the person on a trusted connection, `agent_mux` for
/// Chief (the brain binds as it; `DaemonHomeSource+Create.swift` on the Mac).
public struct ChiefIdentity: Sendable, Hashable {
    public var meID: String
    public var chiefID: String
    public var title: String
    /// Chief's avatar text: an emoji or one or two letters, white on the
    /// monogram gradient everywhere Chief is drawn (Home's pin, the chat
    /// header, the details page). The Mac's Chief Settings set it
    /// (`optchat/profile.json`); "C" until the Mac sends one.
    public var avatar: String

    public static let defaultAvatar = "C"

    public init(meID: String = "user_local", chiefID: String = "agent_mux", title: String = "Chief",
                avatar: String = ChiefIdentity.defaultAvatar) {
        self.meID = meID
        self.chiefID = chiefID
        self.title = title
        self.avatar = avatar
    }

    public static let standard = ChiefIdentity()

    public var me: ConversationParticipant {
        ConversationParticipant(id: meID, name: "You", initials: "", colorHex: "#8E8E93", isMe: true)
    }

    public var chief: ConversationParticipant {
        ConversationParticipant(id: chiefID, name: title, initials: avatar, colorHex: "#636366", isMe: false)
    }

    public func info(id: String) -> ConversationInfo {
        ConversationInfo(id: id, title: title, kind: .direct, participants: [me, chief],
                         listState: ConversationListState(pinned: true, pinOrder: 0))
    }
}
