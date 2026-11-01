import CmuxNextBridge
import CmuxNextSettings
import CmuxNextSidebar

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
/// it. `afterCurrent` is right after the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` is the last slot of the current workspace's group; outside a
/// group it leaves the daemon's place, the end of the loose rows. So a new
/// workspace opened from inside a group stays in it under every value (cx-caoh).
struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    var current: String?
    /// The machine of `current`, when it was known at the press. A cold
    /// sidebar can briefly omit that row while its document projection catches
    /// up; only an omitted row on this same machine needs to defer placement.
    /// Nil when `current` shows in a band of the window's layout (pinned, the
    /// top region, a custom section): the list leaves that row out on purpose,
    /// so its absence is no stale layout and `afterCurrent` falls back to `top`.
    var currentMachine: String?
    /// Its creator named `placement` (`agents chat new --top`): the daemon placed it by the setting, so `move` writes even its top slot.
    var named = false

    /// The current row is expected in this machine section but is not in the
    /// stale layout yet. Returning true keeps Cmd-N pending until the row is
    /// realized, instead of resolving the slot against an empty layout. Only
    /// while the window's rows are a projection behind the sidebar document
    /// (`catchingUp`, `layoutCatchingUp(rowsAt:)`): once they have caught up, a row still missing was
    /// left out on purpose (a filter, another space, a close) and the slot
    /// falls back as documented.
    func awaitsCurrentAnchor(section: SectionID, in sections: [SidebarRowSection], home: String? = nil, catchingUp: Bool) -> Bool {
        guard catchingUp, placement == .afterCurrent, let current, let currentMachine,
              current != home,
              case let .machine(machine) = section, machine.rawValue == currentMachine,
              !sections.flatMap(\.workspaces).contains(where: { $0.id.rawValue == current }) else { return false }
        return true
    }

    /// Whether a window's rows built at `rowsAt` (the document's `shownChanges` then; nil: not built from its
    /// projection) are behind the app's sidebar document `store`: its drawn projection is behind its version, or the
    /// window's rows pass has not run since the projection changed (a cold or updated layout a hop before its rows show).
    static func layoutCatchingUp(_ store: SidebarDocStore?, rowsAt: UInt64? = nil) -> Bool {
        guard let store, store.isActive else { return false }
        return store.shown == nil || store.shownVersion != store.version || rowsAt != store.shownChanges
    }

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id. `catchingUp`: the window's rows are a
    /// projection behind (`awaitsCurrentAnchor`).
    func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            if let current, current != id, current != home,
               WorkspaceSlot.bottom(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .bottom(anchor: current)
            }
            return nil
        case .afterCurrent:
            if awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) { return nil }
            if let current, current != id, current != home,
               WorkspaceSlot.below(current).position(moving: [id], section: section, in: sections) != nil {
                return .below(current)
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
    /// create already put it at ``slot(for:section:in:home:catchingUp:)``: the daemon places every new workspace
    /// by `workspaces.newPlacement` in the commit that creates it (first below Home under `top`,
    /// last under `bottom`), so a second write would be a second state change and a second render
    /// for the same order (plans/cmux-next/sidebar-ordering-DESIGN.md). Only a slot the daemon does
    /// not know is moved to: inside the current workspace's group, after the window's current one.
    func move(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?, catchingUp: Bool = false) -> WorkspaceSlot? {
        guard let slot = slot(for: id, section: section, in: sections, home: home, catchingUp: catchingUp) else { return nil }
        if !named, slot == Self.top(for: id, section: section, in: sections, home: home) { return nil }
        return slot
    }

    /// The slot for a new workspace made inside group `group` from the group itself (its header's
    /// +, a double-click in its empty part), whose workspace rows are `members` in order: its
    /// first slot under `top`, right below the window's current workspace under `afterCurrent`
    /// when that one is a member (else the first slot), its last slot under `bottom`.
    func slot(inGroup group: GroupID, members: [String]) -> WorkspaceSlot {
        let first = members.first.map { WorkspaceSlot.top(anchor: $0) } ?? .endOfGroup(group)
        switch placement {
        case .top: return first
        case .afterCurrent:
            if let current, members.contains(current) { return .below(current) }
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
}

/// Registering new workspaces for placement, outside `WindowManager` (its
/// type budget): the rule for a window, and the pending placement that
/// `WindowManager.applyPendingPlacements` resolves once the daemon reports
/// the workspace.
@MainActor
enum NewWorkspacePlacements {
    /// `workspaces.newPlacement` for a new workspace of window `windowID`
    /// (nil: the window reconcile gives it, the most recent open one), with
    /// the workspace that window shows now. Read it before the claim selects
    /// the new workspace.
    static func rule(for windowID: String?, in windows: WindowManager) -> NewWorkspaceDefaultSlot {
        let placement = windows.services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback
        let window = windowID ?? windows.registry.value.mostRecentOpen()
        let current = window.flatMap { windows.states[$0]?.workspaceID }
        let model = window.flatMap { windows.controller(for: $0)?.sidebar.model }
        let currentMachine = current.flatMap { id in
            model.map { shownInBand(id, layout: $0.layout, room: $0.activeProfileID?.rawValue,
                                   legacy: windows.services.sidebarLayout.unavailableReason != nil, machines: windows.services.machines) } == true
                ? nil : windows.services.machines.daemon(forWorkspace: id)?.machineID
        }
        return NewWorkspaceDefaultSlot(placement: placement, current: current, currentMachine: currentMachine)
    }

    /// Whether workspace `id` shows outside the window's workspace list: an item of a section of
    /// `layout` that shows in the window's space `room` (pinned, the top region, a custom section), or, while
    /// the sidebar layout is unavailable (`legacy`), a pin (`workspace-pin-v1`, the Pinned list section).
    static func shownInBand(_ id: String, layout: SidebarLayoutDocument, room: String?, legacy: Bool, machines: MachineRegistry) -> Bool {
        // The list's own projection (`SidebarTopProjection`): the pin flag only while pins are not layout tiles.
        if legacy { return machines.workspace(id: id)?.0.pinned == true }
        guard let ref = WorkspaceLayoutRefs(machines: machines).ref(forWorkspace: id) else { return false }
        return layout.sections.contains { $0.isVisible(inRoom: room) && $0.items.contains { $0.ref == ref } }
    }

    /// Whether window `windowID` lists workspace `id` once its rows catch up: no other window owns it and the
    /// window's space shows it. A cold Cmd-N waits only for such a row.
    static func lists(_ id: String, in windowID: String, windows: WindowManager) -> Bool {
        if let owner = windows.registry.value.owner(of: id), owner != windowID { return false }
        guard let profile = windows.controller(for: windowID)?.state.profileID else { return true }
        let machines = windows.services.machines
        return WindowProfiles.shows(id, profile: profile, machines: machines, membership: WindowProfiles.membership(machines))
    }

    /// How long a placement waits for the window's current row (`awaitsCurrentAnchor`) before it resolves by the
    /// fallback: a cold layout shows its rows well within it; a row that never comes cannot hold the placement.
    static let anchorWaitLimit: Duration = .seconds(3)

    /// Places workspace `id` at `slot`, else by `byDefault`, in window
    /// `windowID` (nil: the window that lists it): now when it is mirrored,
    /// else once the daemon reports it. `then` runs after, with the sidebar.
    static func expect(_ id: String, in windowID: String?, slot: WorkspaceSlot? = nil, byDefault: NewWorkspaceDefaultSlot?,
                       then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil, windows: WindowManager) {
        guard slot != nil || byDefault != nil || then != nil else { return }
        if windows.pendingPlacements[id] == nil { windows.pendingPlacementOrder.append(id) }
        windows.pendingPlacements[id] = PendingPlacement(window: windowID, slot: slot, byDefault: byDefault, then: then)
        if windows.services.machines.workspace(id: id) != nil { windows.applyPendingPlacements(live: [id]) }
    }

    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }

    /// The index a group formed for a new workspace takes (`createGroup`'s `index`, New Workspace in
    /// New Group): first under `workspaces.newPlacement` `top` (the default), else last (`Int.max`).
    /// The same rule as the Chief's subagent groups (`new_group_index` in optchat-chief workspaces.rs).
    static func newGroupIndex(_ services: AppServices) -> Int {
        newGroupIndex(for: services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback)
    }

    static func newGroupIndex(for placement: NewWorkspacePlacement) -> Int { placement == .top ? 0 : .max }
}
