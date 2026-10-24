public import CmuxHomeCore
import Foundation

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
    /// A large group's member count (``members`` is then a roster); nil when ``members`` is everyone.
    public var memberCount: Int?
    /// When the group's Chiefs answer (the Chiefs Reply row); nil hides the row (a DM, a group
    /// without a Chief, or a local group, whose owner has no such setting).
    public var chiefReplies: ChiefReplyPolicy?

    public init(conversation: ConversationID, isGroup: Bool, title: String, displayTitle: String, members: [HomeGroupMember],
                canMute: Bool, muted: Bool, memberCount: Int? = nil, chiefReplies: ChiefReplyPolicy? = nil) {
        self.conversation = conversation
        self.isGroup = isGroup
        self.title = title
        self.displayTitle = displayTitle
        self.members = members
        self.canMute = canMute
        self.muted = muted
        self.memberCount = memberCount
        self.chiefReplies = chiefReplies
    }

    /// The members list's header: "Members", or "5,000 members" for a large group.
    public var membersHeader: String { Self.membersHeader(count: memberCount) }

    /// The header for `count` members; nil gives the plain "Members".
    public static func membersHeader(count: Int?) -> String {
        membersHeader(count: count, bundle: HomeConversationStrings.bundle, locale: .current)
    }

    /// ``membersHeader(count:)`` read from `bundle` in `locale`; a test passes one language's
    /// table (`en.lproj`) and its locale, so the result does not depend on the runner's language.
    static func membersHeader(count: Int?, bundle: Bundle, locale: Locale) -> String {
        guard let count else { return HomeConversationStrings.infoMembers(bundle: bundle, locale: locale) }
        return HomeConversationStrings.infoMemberCount(count, bundle: bundle, locale: locale)
    }
}
