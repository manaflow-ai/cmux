public import Foundation
public import CmuxNextDesignTokens

/// What a group's hover card says: its title and one block of lines per shown section, in the
/// order `GroupHoverCardOptions` picks. The rule (which sections show, the counts, the latest
/// member, the branch and port lists) is cmux-layout-reducer's (`group_hover_summary`, through
/// `cmux_layout_reducer_json`, once per card show); this type puts its typed lines into the
/// localized words (`GroupHoverCardStrings`). The sidebar's group headers and the tab strip's
/// group chips build it from their members, and `GroupHoverCardView` draws it.
public nonisolated struct GroupHoverCardSummary: Sendable, Hashable {
    /// The kind of group, for the member count's noun.
    public enum Kind: Sendable, Hashable {
        case workspaceGroup, tabGroup
    }

    /// The status line's color, mapped to a `HoverCardTone` where the card draws it (that type is
    /// main-actor isolated; this summary is built anywhere).
    public enum Tone: String, Sendable, Hashable, Decodable {
        case secondary, working, attention, danger
    }

    /// One shown section and its lines (never empty).
    public struct Block: Sendable, Hashable {
        public var section: GroupHoverCardOptions.Section
        public var lines: [String]
        /// The status block's tone: working, waiting or failed when one member is.
        public var tone: Tone
    }

    public var title: String
    public var blocks: [Block]

    /// Every line the card shows, the title first (tests, accessibility, `debug.hover_cards`).
    public var lines: [String] { [title] + blocks.flatMap(\.lines) }

    /// The summary of `members` as `options` asks for it, at `now`.
    /// - Parameters:
    ///   - title: The group's name (the caller supplies a default for an unnamed group).
    ///   - kind: Workspace group or tab group: the count reads "Workspaces" or "Tabs".
    ///   - members: The members in group order.
    ///   - options: Which sections show and in what order.
    ///   - now: The time ages are measured from.
    public static func make(title: String, kind: Kind, members: [GroupHoverCardMember],
                            options: GroupHoverCardOptions, now: Date) -> Self {
        let request = GroupHoverCardSummaryWire.Request(
            members: members.map(GroupHoverCardSummaryWire.Member.init), sections: options.sections.map(\.rawValue),
            max_members: options.maxMembers, now: now.timeIntervalSinceReferenceDate)
        // The rule cannot refuse a request this type builds; an empty card is the safe answer if it did.
        let blocks = (GroupHoverCardSummaryWire.run(request)?.blocks ?? []).compactMap { block in block.words(kind) }
        return Self(title: title, blocks: blocks)
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "12m", "5h"; "Just now" when the rule says so (under a minute).
    static func age(seconds: Double, justNow: Bool) -> String {
        justNow ? GroupHoverCardStrings.justNow : ageFormatter.string(from: seconds) ?? GroupHoverCardStrings.justNow
    }
}
