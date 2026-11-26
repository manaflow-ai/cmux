/// One rendered row.
public struct PaletteRow: Identifiable {
    public let item: PaletteItem
    /// Scalar offsets into `item.title` that matched the query.
    public let highlights: [Int]
    public let score: Int

    public var id: String { item.id }
}

/// A titled group of rendered rows.
public struct PaletteResultSection: Identifiable {
    public let section: PaletteSection
    public let rows: [PaletteRow]

    public var id: String { section.id }
    public var title: String { section.title }
}

/// The palette v2 look's groups (`PaletteV2Look.isOn`): on the root and Search pages every row shows under one
/// of four small headers, in the rail's order.
public nonisolated enum PaletteV2Group: String, CaseIterable, Sendable {
    case workspaces, sessions, commands, agents

    /// The header's and the rail's title.
    public var title: String {
        switch self {
        case .workspaces: PaletteStrings.sectionWorkspaces
        case .sessions: PaletteStrings.v2GroupSessions
        case .commands: PaletteStrings.commandsTitle
        case .agents: PaletteStrings.v2GroupAgents
        }
    }

    /// The id of the section a group's rows show under.
    public var sectionID: String { "v2.\(rawValue)" }

    /// The group a grouped section id (``sectionID``) names.
    public init?(sectionID: String) {
        guard sectionID.hasPrefix("v2.") else { return nil }
        self.init(rawValue: String(sectionID.dropFirst(3)))
    }
}

/// One rail entry (`PaletteV2Look.rail`): All (`group` nil) or a group, with the rows it holds now.
public nonisolated struct PaletteV2RailEntry: Equatable, Sendable {
    public let group: PaletteV2Group?
    public let count: Int

    public init(group: PaletteV2Group?, count: Int) {
        self.group = group
        self.count = count
    }

    /// The entry's title: "All" or the group's.
    public var title: String { group?.title ?? PaletteStrings.v2RailAll }
}

/// The v2 look's regrouping of a page's ranked rows (plans: palette v2, variants A-C). Linear in the rows.
enum PaletteV2Grouping {
    /// Sections whose rows are workspaces.
    private static let workspaceSections: Set<String> = ["workspaces", "findWork.workspaces", "groups"]
    /// Sections whose rows are sessions: open tabs and panes, and closed tabs from history.
    private static let sessionSections: Set<String> = ["tabs", "panes", "search.history.closed", "history.closed"]
    /// Sections whose rows are agents: the agent chats and agent sessions Search's contributions bring
    /// (the ones that also make up the Chats & agents scope, `PaletteScopeID.chats`).
    private static let agentSections: Set<String> = [
        "search.agentChats", "agentChats", "search.history.agents", "history.agents", PaletteScopeID.chats.rawValue,
    ]

    /// The group of `row`, shown today under the section `sectionID` (Recent, Pinned and Suggested rows keep their
    /// own `item.section`, so a recent workspace is still a workspace). A row with an agent brand is an agent.
    static func group(of row: PaletteRow, in sectionID: String) -> PaletteV2Group {
        if row.item.brand != nil { return .agents }
        return group(forSection: sectionID) ?? group(forSection: row.item.section.id) ?? .commands
    }

    private static func group(forSection id: String) -> PaletteV2Group? {
        if workspaceSections.contains(id) { return .workspaces }
        if sessionSections.contains(id) { return .sessions }
        if agentSections.contains(id) { return .agents }
        return PaletteV2Group(sectionID: id)
    }

    /// The section a group's rows show under.
    static func section(for group: PaletteV2Group) -> PaletteSection {
        PaletteSection(id: group.sectionID, title: group.title, order: PaletteV2Group.allCases.firstIndex(of: group) ?? 0)
    }

    /// `sections` regrouped: each row under its group, in the order it had (its rank); the groups in the order of
    /// their best row, so the top match's group comes first and the top match stays the first row. Empty groups do
    /// not show; a row listed twice (Recent and its own section) shows once, where it showed first.
    static func regroup(_ sections: [PaletteResultSection]) -> [PaletteResultSection] {
        // The scope bar's token suggestions ("Session contains: X") stay first, under their own header.
        if let first = sections.first, first.id == PaletteScopeFilter.suggestionsSectionID {
            return [first] + regroup(Array(sections.dropFirst()))
        }
        var order: [PaletteV2Group] = []
        var rows: [PaletteV2Group: [PaletteRow]] = [:]
        var seen = Set<String>()
        for section in sections {
            for row in section.rows where seen.insert(row.id).inserted {
                let kind = Self.group(of: row, in: section.id)
                if rows[kind] == nil { order.append(kind) }
                rows[kind, default: []].append(row)
            }
        }
        return order.map { PaletteResultSection(section: Self.section(for: $0), rows: rows[$0] ?? []) }
    }

    /// `grouped` (``regroup(_:)``'s result) with only the rows whose ids are in `ids`; empty groups dropped.
    static func keeping(_ ids: Set<String>, of grouped: [PaletteResultSection]) -> [PaletteResultSection] {
        grouped.compactMap { section in
            let rows = section.rows.filter { ids.contains($0.id) }
            return rows.isEmpty ? nil : PaletteResultSection(section: section.section, rows: rows)
        }
    }

    /// `grouped` narrowed to the rail's choice: All (nil) keeps every group.
    static func filter(_ grouped: [PaletteResultSection], to group: PaletteV2Group?) -> [PaletteResultSection] {
        guard let group else { return grouped }
        return grouped.filter { $0.id == group.sectionID }
    }

    /// The rail for `grouped`: All with every row, then each group that has rows, in the rail's fixed order (the rail
    /// does not reorder as the ranking does).
    static func railEntries(_ grouped: [PaletteResultSection]) -> [PaletteV2RailEntry] {
        var counts: [PaletteV2Group: Int] = [:]
        var total = 0
        for section in grouped {
            total += section.rows.count
            if let group = PaletteV2Group(sectionID: section.id) { counts[group, default: 0] += section.rows.count }
        }
        var entries = [PaletteV2RailEntry(group: nil, count: total)]
        for group in PaletteV2Group.allCases {
            if let count = counts[group], count > 0 { entries.append(PaletteV2RailEntry(group: group, count: count)) }
        }
        return entries
    }
}
