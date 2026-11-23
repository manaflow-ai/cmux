import Foundation

/// The sidebar group `agent.openSessionWorkspace` (`acpmux new --group`, `cmux agent open --group`) names
/// by its label: which group a workspace joins and which row a re-homed lane reuses.
public extension SidebarEdits {
    /// Sidebar group arguments are labels. Object ids are rejected so an
    /// automation retry cannot turn an id into a persistent visible title.
    static func validGroupName(_ name: String) -> Bool {
        var request = RustEditRequest("valid_group_name")
        request.name = name
        return RustSidebarClient.call("sidebar_edits", request, as: Bool.self) ?? false
    }

    /// The first listed group named `name` that may hold workspace `id` (the drag's rule,
    /// `canMove`: a machine row's group holds that machine's workspaces), in any section and
    /// either organization; nil when none may. Only the first group of that name was tried before, so a
    /// row it could not hold got a new group of that name each time (nine "GUI push · lanes", 2026-10-22).
    /// A group of exactly that name wins; only when none is listed, one whose name is the same label typed
    /// another way ("gui push", "GUI push "). `machine`: the workspace's machine, for a workspace `sections`
    /// leaves out (a new one held until it lists in its group, ``GroupJoinHold``). The shared rule:
    /// `sidebar_edits` `group_named`.
    static func group(named name: String, accepting id: WorkspaceID, in sections: [SidebarSection], machine: MachineID? = nil) -> GroupID? {
        var request = RustEditRequest("group_named", sections: RustSidebarEdits(sections).sections)
        (request.name, request.id, request.machine) = (name, id.rawValue, machine?.rawValue)
        return (RustSidebarClient.call("sidebar_edits", request, as: String?.self) ?? nil).map(GroupID.init)
    }

    /// The row of this Mac titled `name` in a group named `group`: the workspace a lane of that name already
    /// has there (the launcher titles it with the lane's name; a row renamed since gets a new row, as before).
    static func predecessor(named name: String, inGroup group: String, in sections: [SidebarSection]) -> WorkspaceID? {
        predecessor(named: name, inGroup: group, inEach: [sections])
    }

    /// `predecessor(named:inGroup:in:)` across several sidebars (every window lists only its own workspaces):
    /// a group of exactly that name in any of them wins over the same label typed another way in an earlier
    /// one. The shared rule: `sidebar_edits` `predecessor`.
    static func predecessor(named name: String, inGroup group: String, inEach sidebars: [[SidebarSection]]) -> WorkspaceID? {
        var request = RustEditRequest("predecessor")
        (request.name, request.group) = (name, group)
        request.sidebars = sidebars.map { sections in
            groups(in: sections).map { listed in
                RustNamedGroup(name: listed.name, rows: listed.workspaces.map {
                    RustNamedRow(id: $0.id.rawValue, title: $0.title, machine: $0.machineID.rawValue)
                })
            }
        }
        return (RustSidebarClient.call("sidebar_edits", request, as: String?.self) ?? nil).map(WorkspaceID.init)
    }

    /// `sections` without the workspace rows `ids`: rows another row stands in for (a pending create's, at its slot), or
    /// held out of the list (``GroupJoinHold``).
    static func removing(_ ids: Set<String>, from sections: [SidebarSection]) -> [SidebarSection] {
        guard !ids.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(workspace):
                    return ids.contains(workspace.id.rawValue) ? nil : node
                case var .group(group):
                    group.workspaces.removeAll { ids.contains($0.id.rawValue) }
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }
}
