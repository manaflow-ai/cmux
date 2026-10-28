package import Foundation

/// What a group's hover card shows (Lawrence 2026-10-20: "hovering on workspace group or tab group
/// for a while should still show the card, like summary stuff, and should be fully customizable
/// too"), from `sidebar.hoverCards.groups.*` in cmux.json. The settings applier writes it into
/// `DesignSettings.groupHoverCard`; the sidebar's group headers and the tab strip's group chips
/// read the same value, so one setting changes both cards the same way.
public nonisolated struct GroupHoverCardOptions: Sendable, Hashable {
    /// One part of a group card.
    public enum Section: String, Sendable, Hashable, CaseIterable {
        /// How many members work, wait, failed or have unread items ("Working: 2 · Unread: 3").
        case status
        /// The member count and the members' names, in group order.
        case members
        /// The member that changed last, and how long ago.
        case activity
        /// The members' branches, each once.
        case git
        /// The members' listening ports, each once.
        case ports
    }

    /// Which part leads the card; the others follow in their usual order.
    public enum Order: String, Sendable, Hashable, CaseIterable {
        /// Status, members, activity, branches, ports (the default).
        case status
        /// Members first: the card reads as a list of what is in the group.
        case members
        /// The latest activity first: what changed last leads.
        case activity

        /// The sections in the order the card shows them.
        public var sections: [Section] {
            let lead: Section = switch self {
            case .status: .status
            case .members: .members
            case .activity: .activity
            }
            return [lead] + Section.allCases.filter { $0 != lead }
        }
    }

    /// Sidebar workspace group headers open a card.
    public var workspaceGroups = true
    /// Tab strip group chips open a card.
    public var tabGroups = true
    /// How long the pointer rests on a group before its card opens. Longer than a row's card by
    /// default: the person asked for "a while", and a sweep across headers must open none.
    public var delay: Duration = .milliseconds(600)
    /// Which part leads.
    public var order: Order = .status
    /// The parts that show; a part not in the set is left out.
    public var shown: Set<Section> = Set(Section.allCases)
    /// The most member names the card lists; the rest show as "+N more".
    public var maxMembers = 8
    /// The range `maxMembers` is clamped to.
    public static let maxMembersRange: ClosedRange<Int> = 1...50

    public init() {}

    /// The shown parts, in the order the card shows them.
    public var sections: [Section] { order.sections.filter(shown.contains) }
}
