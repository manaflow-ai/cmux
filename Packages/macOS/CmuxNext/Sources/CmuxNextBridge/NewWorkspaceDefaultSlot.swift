package import CmuxNextSettings
package import CmuxNextSidebar

/// `workspaces.newPlacement` for one new workspace whose entry point names
/// no place (Cmd-N, the palette, the sidebar's +, `cmux workspace new`, a
/// tab moved to a new workspace, a link or an agent opening one). Resolved once the daemon reports the
/// workspace, against the sidebar of the window that lists it, and written
/// by the row-drag path (`SidebarBridge.place`): personal order in the home
/// session, else the owning daemon's order. Either survives a relaunch and
/// shows in every window.
///
/// The rule: `top` is the first slot of the window's current workspace's
/// group when that one is in a group (Cmd-N in a group keeps the new one in
/// it, at the group's top, Lawrence 2026-10-28); else the first slot of the workspace's machine section, which
/// lists no pinned workspace (they show in the Pinned section above), above
/// every group, and right below the home workspace's row when the list shows
/// it. `beforeCurrent` / `afterCurrent` is right before / after the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` is the last slot of the current workspace's group; outside a
/// group it leaves the daemon's place, the end of the loose rows. So a new
/// workspace opened from inside a group stays in it under every value (cx-caoh).
package struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    package var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    package var current: String?

    /// The known machine of a current row expected in the window's workspace list.
    package var currentMachine: String?

    package init(placement: NewWorkspacePlacement, current: String?, currentMachine: String? = nil) {
        self.placement = placement
        self.current = current
        self.currentMachine = currentMachine
    }

    /// The current row is expected in this machine section but is not in the
    /// stale layout yet. Returning true keeps Cmd-N pending until the row is
    /// realized, instead of resolving the slot against an empty layout. Only
    /// while the window's rows are a projection behind the sidebar document
    /// (`catchingUp`, `layoutCatchingUp(rowsAt:)`): once they have caught up, a row still missing was
    /// left out on purpose (a filter, another space, a close) and the slot
    /// falls back as documented.
    package func awaitsCurrentAnchor(section: SectionID, in sections: [SidebarRowSection], home: String? = nil, catchingUp: Bool) -> Bool {
        guard catchingUp, (placement == .beforeCurrent || placement == .afterCurrent), let current, let currentMachine,
              current != home,
              case let .machine(machine) = section, machine.rawValue == currentMachine,
              !sections.flatMap(\.workspaces).contains(where: { $0.id.rawValue == current }) else { return false }
        return true
    }

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id.
    package func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            if let current, current != id, current != home,
               WorkspaceSlot.bottom(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .bottom(anchor: current)
            }
            return nil
        case .beforeCurrent, .afterCurrent:
            if awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) { return nil }
            let beside: WorkspaceSlot? = current.map { placement == .beforeCurrent ? .above($0) : .below($0) }
            if let current, let beside, current != id, current != home,
               beside.position(moving: [id], section: section, in: sections) != nil {
                return beside
            }
            return Self.top(for: id, section: section, in: sections, home: home)
        case .top:
            if let current, current != id, current != home,
               WorkspaceSlot.top(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .top(anchor: current)
            }
            return Self.top(for: id, section: section, in: sections, home: home)
        }
    }

    /// The move the app sends once the daemon reports new workspace `id`, or nil when the daemon's
    /// create already put it at ``slot(for:section:in:home:)``: the daemon places every new workspace
    /// by `workspaces.newPlacement` in the commit that creates it (first below Home under `top`,
    /// last under `bottom`), so a second write would be a second state change and a second render
    /// for the same order (plans/cmux-next/sidebar-ordering-DESIGN.md). Only a slot the daemon does
    /// not know is moved to: inside the current workspace's group, after the window's current one.
    package func move(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        guard let slot = slot(for: id, section: section, in: sections, home: home, catchingUp: catchingUp) else { return nil }
        if slot == Self.top(for: id, section: section, in: sections, home: home) { return nil }
        return slot
    }

    /// The slot for a new workspace made inside group `group` from the group itself (its header's
    /// +, a double-click in its empty part), whose workspace rows are `members` in order: its
    /// first slot under `top`, right below the window's current workspace under `afterCurrent`
    /// when that one is a member (else the first slot), its last slot under `bottom`.
    package func slot(inGroup group: GroupID, members: [String]) -> WorkspaceSlot {
        let first = members.first.map { WorkspaceSlot.top(anchor: $0) } ?? .endOfGroup(group)
        switch placement {
        case .top: return first
        case .beforeCurrent, .afterCurrent:
            if let current, members.contains(current) { return placement == .beforeCurrent ? .above(current) : .below(current) }
            return first
        case .bottom: return .endOfGroup(group)
        }
    }

    /// First in the section, below a leading home row.
    private static func top(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot {
        let first = sections.first { $0.id == section }?.nodes.lazy.compactMap { node -> String? in
            guard case let .workspace(workspace) = node else { return "" }
            return workspace.id.rawValue == id ? nil : workspace.id.rawValue
        }.first
        if let home, first == home { return .below(home) }
        return .top(anchor: nil)
    }
    /// The neighbour of a new workspace placed at `slot`, else by `byDefault`: right before or after
    /// the window's current workspace (not Home), or the one New Workspace Above or Below names; under
    /// `top` / `bottom`, first / last in its group when it is in one (``NewWorkspaceDefaultSlot``'s rule).
    package static func anchor(slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?, home: String?) -> SidebarDocSections.UnplacedAnchor? {
        switch slot {
        case .above(let id)?: return .before(id)
        case .below(let id)?: return .after(id)
        case nil: break
        default: return nil
        }
        guard let byDefault else { return nil }
        guard let current = byDefault.current, current != home else {
            // No current workspace, or Home: the daemon puts the new one first (`top`'s slot), as the app would.
            return byDefault.placement == .beforeCurrent || byDefault.placement == .afterCurrent ? .first : nil
        }
        switch byDefault.placement {
        case .beforeCurrent: return .before(current, fallbackFirst: true)
        case .afterCurrent: return .after(current, fallbackFirst: true)
        case .top: return .firstInGroupOf(current)
        case .bottom: return .lastInGroupOf(current)
        }
    }
}
