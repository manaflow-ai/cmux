public import CmuxNextSettings
public import CmuxNextSidebar

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
/// it. `afterCurrent` (and its opt-in mirror `beforeCurrent`) is right after (before) the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` is the last slot of the current workspace's group; outside a
/// group it leaves the daemon's place, the end of the loose rows. So a new
/// workspace opened from inside a group stays in it under every value (cx-caoh).
public struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    public var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    public var current: String?
    /// The machine of `current`, when it was known at the press. A cold
    /// sidebar can briefly omit that row while its document projection catches
    /// up; only an omitted row on this same machine needs to defer placement.
    /// Nil when `current` shows in a band of the window's layout (pinned, the
    /// top region, a custom section): the list leaves that row out on purpose,
    /// so its absence is no stale layout and `afterCurrent` falls back to `top`.
    public var currentMachine: String?
    /// Its creator named `placement` (`agents chat new --top`): the daemon placed it by the setting, so `move` writes even its top slot.
    public var named = false

    /// The gaps right below and right above `current` in the window's rows at the press (``gaps(around:in:)``):
    /// where the new workspace goes when `current` closes before it is listed (by its next row, else its previous
    /// one), instead of the section's top.
    public var currentGaps: [WorkspaceGap]

    public init(placement: NewWorkspacePlacement, current: String? = nil, currentMachine: String? = nil, named: Bool = false,
                currentGaps: [WorkspaceGap] = []) {
        self.placement = placement
        self.current = current
        self.currentMachine = currentMachine
        self.named = named
        self.currentGaps = currentGaps
    }

    /// The gaps right below and right above workspace `current` in its container of the window's `shown` rows (its
    /// group, else the loose rows; pending rows left out), none when they do not list it.
    public static func gaps(around current: String?, in shown: [SidebarRowSection]?) -> [WorkspaceGap] {
        guard let current, let shown else { return [] }
        let sections = SidebarRowSection.withoutPlaceholders(shown)
        return [WorkspaceSlot.below(current), .above(current)].compactMap { slot in
            slot.position(moving: [], besides: current, in: sections).flatMap { WorkspaceGap($0, in: sections) }
        }
    }

    /// Right below `current`, else where it was when it closed during the create (`currentGaps`), else the end of
    /// the group it was in: what a new workspace made from the selected row resolves to (Leo 2026-11-06).
    private var belowCurrentOrItsPlace: [WorkspaceSlot] {
        (current.map { [WorkspaceSlot.below($0)] } ?? []) + currentGaps.map { .gap($0) }
            + (currentGaps.first?.group.map { [.endOfGroup($0)] } ?? [])
    }

    /// `beforeCurrent`'s mirror of ``belowCurrentOrItsPlace``: right above `current`, else where it was when it
    /// closed during the create (the gap above it first, by its previous row), else the end of the group it was in.
    private var aboveCurrentOrItsPlace: [WorkspaceSlot] {
        (current.map { [WorkspaceSlot.above($0)] } ?? []) + currentGaps.reversed().map { .gap($0) }
            + (currentGaps.first?.group.map { [.endOfGroup($0)] } ?? [])
    }

    /// The slots of `afterCurrent` or `beforeCurrent`, in preference order; empty under `top` and `bottom`.
    private var besideCurrentOrItsPlace: [WorkspaceSlot] {
        switch placement {
        case .afterCurrent: belowCurrentOrItsPlace
        case .beforeCurrent: aboveCurrentOrItsPlace
        case .top, .bottom: []
        }
    }

    /// Whether this rule places beside the window's current workspace (`afterCurrent`, `beforeCurrent`).
    nonisolated public var placesBesideCurrent: Bool { placement == .afterCurrent || placement == .beforeCurrent }

    /// The current row is expected in this machine section but is not in the
    /// stale layout yet. Returning true keeps Cmd-N pending until the row is
    /// realized, instead of resolving the slot against an empty layout. Only
    /// while the window's rows are a projection behind the sidebar document
    /// (`catchingUp`, `layoutCatchingUp(_:rowsAt:)`): once they have caught up, a row still missing was
    /// left out on purpose (a filter, another space, a close) and the slot
    /// falls back as documented.
    public func awaitsCurrentAnchor(section: SectionID, in sections: [SidebarRowSection], home: String? = nil, catchingUp: Bool) -> Bool {
        // Every placement: `top` and `bottom` resolve inside the current workspace's group too, so a slot read
        // before its row lists drew the row at the section's top or end, then moved it into the group.
        guard catchingUp, let current, let currentMachine,
              current != home,
              case let .machine(machine) = section, machine.rawValue == currentMachine,
              !sections.flatMap(\.workspaces).contains(where: { $0.id.rawValue == current }) else { return false }
        return true
    }

    /// Whether a window's rows built at `rowsAt` (the document's `shownChanges` then; nil: not built from its
    /// projection) are behind the app's sidebar document `store`: its drawn projection is behind its version, or the
    /// window's rows pass has not run since the projection changed (a cold or updated layout a hop before its rows show).
    public static func layoutCatchingUp(_ store: SidebarDocStore?, rowsAt: UInt64? = nil) -> Bool {
        guard let store, store.isActive else { return false }
        return store.shown == nil || store.shownVersion != store.version || rowsAt != store.shownChanges
    }

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id. `catchingUp`: the window's rows are a
    /// projection behind (`awaitsCurrentAnchor`).
    public func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            if let current, current != id, current != home,
               WorkspaceSlot.bottom(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .bottom(anchor: current)
            }
            return nil
        case .afterCurrent, .beforeCurrent:
            if awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) { return nil }
            if current != id, current != home,
               let slot = besideCurrentOrItsPlace.first(where: { $0.position(moving: [id], section: section, in: sections) != nil }) {
                return slot
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

    /// The move the app sends once the daemon reports new workspace `id`, or nil when the daemon's create already put it
    /// at ``slot(for:section:in:home:catchingUp:)``: the daemon places every new workspace by `workspaces.newPlacement` in
    /// the commit that creates it (first below Home under `top`, last under `bottom`), so a second write would be a second
    /// state change and render for the same order (plans/cmux-next/sidebar-ordering-DESIGN.md). Only a slot the daemon
    /// does not know is moved to: in the current workspace's group, and every `afterCurrent` or `beforeCurrent` one (an
    /// older daemon anchors it to its active workspace, which a top page such as Home leaves on the parked one, #32731;
    /// a create the daemon placed by the window's own rule, `WorkspacePlacementLedger.placedByDaemon`, sends none).
    public func move(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        guard let slot = slot(for: id, section: section, in: sections, home: home, catchingUp: catchingUp) else { return nil }
        if !named, !placesBesideCurrent, slot == Self.top(for: id, section: section, in: sections, home: home) { return nil }
        return slot
    }

    /// The slot for a new workspace made inside group `group` from the group itself (its header's
    /// +, a double-click in its empty part), whose workspace rows are `members` in order: its
    /// first slot under `top`, right below (`beforeCurrent`: above) the window's current workspace under
    /// `afterCurrent` when that one is a member (where it was, should it close during the create), else the group's
    /// end (Leo 2026-11-06), its last slot under `bottom`.
    public func slot(inGroup group: GroupID, members: [String]) -> WorkspaceSlot {
        let first = members.first.map { WorkspaceSlot.top(anchor: $0) } ?? .endOfGroup(group)
        switch placement {
        case .top: return first
        case .afterCurrent, .beforeCurrent:
            if let current, members.contains(current) { return .first(besideCurrentOrItsPlace + [.endOfGroup(group)]) }
            return .endOfGroup(group)
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
    public static func anchor(slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?, home: String?) -> SidebarDocSections.UnplacedAnchor? {
        switch slot {
        case .above(let id)?: return .before(id)
        case .below(let id)?: return .after(id)
        case nil: break
        default: return nil
        }
        guard let byDefault else { return nil }
        guard let current = byDefault.current, current != home else {
            // No current workspace, or Home: the daemon puts the new one first (`top`'s slot), as the app would.
            return byDefault.placesBesideCurrent ? .first : nil
        }
        switch byDefault.placement {
        case .beforeCurrent: return .before(current, fallbackFirst: true)
        case .afterCurrent: return .after(current, fallbackFirst: true)
        case .top: return .firstInGroupOf(current)
        case .bottom: return .lastInGroupOf(current)
        }
    }
}
