public import CmuxHomeCore

/// What the group info sheet shows of one DM or group: a value snapshot, so the
/// sheet never holds the store.
public struct HomeGroupInfo: Hashable, Sendable {
    public let conversation: ConversationID
    /// A group (renamed, members added and removed, left); false for a DM.
    public var isGroup: Bool
    /// The name the owner holds; empty when it shows the members' names.
    public var title: String
    /// The name the list row shows (the title, else the members' names).
    public var displayTitle: String
    /// Me first, then the others in the owner's order.
    public var members: [HomeGroupMember]
    /// Hide Alerts is offered (a Cloud DM or group its owner lists).
    public var canMute: Bool
    /// Alerts are hidden.
    public var muted: Bool

    public init(conversation: ConversationID, isGroup: Bool, title: String, displayTitle: String, members: [HomeGroupMember],
                canMute: Bool, muted: Bool) {
        self.conversation = conversation
        self.isGroup = isGroup
        self.title = title
        self.displayTitle = displayTitle
        self.members = members
        self.canMute = canMute
        self.muted = muted
    }
}
