import Foundation

/// The sidebar group `agent.openSessionWorkspace` (`acpmux new --group`, `cmux agent open --group`) names
/// by its label: which group a workspace joins and which row a re-homed lane reuses.
public extension SidebarEdits {
    /// Sidebar group arguments are labels. Object ids are rejected so an
    /// automation retry cannot turn an id into a persistent visible title.
    static func validGroupName(_ name: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        let lower = label.lowercased()
        if ["grp_", "ws_", "tab_", "pane_", "win_", "workspace_group:"].contains(where: lower.hasPrefix) {
            return false
        }
        return UUID(uuidString: label) == nil
    }

    /// The first listed group named `name` that may hold workspace `id` (the drag's rule,
    /// `canMove`: a machine row's group holds that machine's workspaces), in any section and
    /// either organization; nil when none may. Only the first group of that name was tried before, so a
    /// row it could not hold got a new group of that name each time (nine "GUI push · lanes", 2026-10-22).
    /// A group of exactly that name wins; only when none is listed, one whose name is the same label (`sameGroupName`).
    static func group(named name: String, accepting id: WorkspaceID, in sections: [SidebarSection]) -> GroupID? {
        let groups = { (exact: Bool) -> GroupID? in
            for section in sections {
                for case let .group(group) in section.nodes where exact ? group.name == name : sameGroupName(group.name, name) {
                    if canMove([id], toGroup: group.id, in: sections) { return group.id }
                }
            }
            return nil
        }
        // Only when no group of exactly that name is listed: the same label typed another way ("gui push",
        // "GUI push "), so a variant joins the group the person meant instead of making a stray one beside it.
        // A listed exact group that cannot hold the workspace still gets a new group of that name, as before.
        if let exact = groups(true) { return exact }
        return listsGroup(exactly: name, in: [sections]) ? nil : groups(false)
    }

    /// Whether two group names are one label: equal once outer whitespace is trimmed, ignoring case.
    static func sameGroupName(_ listed: String, _ asked: String) -> Bool {
        let trim = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(listed).caseInsensitiveCompare(trim(asked)) == .orderedSame
    }

    /// The row of this Mac titled `name` in a group named `group`: the workspace a lane of that name already
    /// has there (the launcher titles it with the lane's name; a row renamed since gets a new row, as before).
    /// Only this Mac's rows: the chat opens on this Mac's daemon, so another machine's row is never reused.
    /// As in `group(named:accepting:in:)`, a group of exactly that name wins over the same label typed another way.
    static func predecessor(named name: String, inGroup group: String, in sections: [SidebarSection]) -> WorkspaceID? {
        predecessor(named: name, inGroup: group, inEach: [sections])
    }

    /// `predecessor(named:inGroup:in:)` across several sidebars (every window lists only its own workspaces):
    /// a group of exactly that name in any of them wins over the same label typed another way in an earlier one.
    static func predecessor(named name: String, inGroup group: String, inEach sidebars: [[SidebarSection]]) -> WorkspaceID? {
        let rows = { (exact: Bool) -> WorkspaceID? in
            for sections in sidebars {
                for section in sections {
                    for case let .group(listed) in section.nodes where exact ? listed.name == group : sameGroupName(listed.name, group) {
                        if let row = listed.workspaces.first(where: { $0.title == name && $0.machineID == .local }) { return row.id }
                    }
                }
            }
            return nil
        }
        // A listed group of exactly that name without the row gets a new row in it, as before; the same label
        // typed another way is tried only when no sidebar lists a group of exactly that name.
        if let exact = rows(true) { return exact }
        return listsGroup(exactly: group, in: sidebars) ? nil : rows(false)
    }

    /// Whether any of these sidebars lists a group named exactly `name`.
    private static func listsGroup(exactly name: String, in sidebars: [[SidebarSection]]) -> Bool {
        sidebars.contains { sections in
            sections.contains { section in
                section.nodes.contains { node in
                    if case let .group(group) = node { return group.name == name }
                    return false
                }
            }
        }
    }
}
