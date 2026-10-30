public import Foundation
public import CmuxNextDesignTokens

/// What a group's hover card says: its title and one block of lines per shown section, in the
/// order `GroupHoverCardOptions` picks. Pure: the sidebar's group headers and the tab strip's
/// group chips build it from their members, and `GroupHoverCardView` draws it.
public nonisolated struct GroupHoverCardSummary: Sendable, Hashable {
    /// The kind of group, for the member count's noun.
    public enum Kind: Sendable, Hashable {
        case workspaceGroup, tabGroup
    }

    /// The status line's color, mapped to a `HoverCardTone` where the card draws it (that type is
    /// main-actor isolated; this summary is built anywhere).
    public enum Tone: Sendable, Hashable {
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
        var blocks: [Block] = []
        for section in options.sections {
            switch section {
            case .status:
                blocks.append(status(members))
            case .members:
                let shown = members.prefix(max(1, options.maxMembers)).map(\.title)
                var lines = [GroupHoverCardStrings.count(kind, members.count)] + shown.map { "\u{2022} " + $0 }
                if members.count > shown.count { lines.append(GroupHoverCardStrings.more(members.count - shown.count)) }
                blocks.append(Block(section: .members, lines: lines, tone: .secondary))
            case .activity:
                let latest = members.compactMap { member in member.lastActivity.map { (member, $0) } }.max { $0.1 < $1.1 }
                if let (member, date) = latest {
                    blocks.append(Block(section: .activity, lines: [GroupHoverCardStrings.latest(member.title, age: age(since: date, now: now))],
                                        tone: .secondary))
                }
            case .git:
                let branches = unique(members.compactMap(\.branch))
                if !branches.isEmpty {
                    blocks.append(Block(section: .git, lines: [GroupHoverCardStrings.branches(joined(branches))], tone: .secondary))
                }
            case .ports:
                let ports = unique(members.compactMap(\.ports).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
                if !ports.isEmpty {
                    blocks.append(Block(section: .ports, lines: [GroupHoverCardStrings.ports(joined(ports))], tone: .secondary))
                }
            }
        }
        return Self(title: title, blocks: blocks)
    }

    /// "Working: 2 · Waiting: 1 · Unread: 3", or "All idle".
    private static func status(_ members: [GroupHoverCardMember]) -> Block {
        let working = members.count { $0.activity == .working }
        let waiting = members.count { $0.activity == .waiting }
        let failed = members.count { $0.activity == .failed }
        let unread = members.reduce(0) { $0 + max(0, $1.unread) }
        var parts: [String] = []
        if working > 0 { parts.append(GroupHoverCardStrings.working(working)) }
        if waiting > 0 { parts.append(GroupHoverCardStrings.waiting(waiting)) }
        if failed > 0 { parts.append(GroupHoverCardStrings.failed(failed)) }
        if unread > 0 { parts.append(GroupHoverCardStrings.unread(unread)) }
        let tone: Tone = failed > 0 ? .danger : waiting > 0 ? .attention : working > 0 ? .working : .secondary
        return Block(section: .status, lines: [parts.isEmpty ? GroupHoverCardStrings.allIdle : parts.joined(separator: " \u{00B7} ")], tone: tone)
    }

    /// The most values one line names before "+N".
    static let maxListed = 4

    private static func joined(_ values: [String]) -> String {
        let shown = values.prefix(maxListed).joined(separator: ", ")
        return values.count > maxListed ? shown + " " + GroupHoverCardStrings.more(values.count - maxListed) : shown
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "12m", "5h"; "Just now" under a minute.
    static func age(since date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return GroupHoverCardStrings.justNow }
        return ageFormatter.string(from: seconds) ?? GroupHoverCardStrings.justNow
    }
}
