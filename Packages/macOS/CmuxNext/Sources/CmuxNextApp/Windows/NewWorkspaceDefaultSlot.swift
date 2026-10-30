import CmuxNextBridge
import CmuxNextDaemon
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
/// it. `beforeCurrent` / `afterCurrent` is right before / after the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` is the last slot of the current workspace's group; outside a
/// group it leaves the daemon's place, the end of the loose rows. So a new
/// workspace opened from inside a group stays in it under every value (cx-caoh).
struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    var current: String?

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id.
    func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            if let current, current != id, current != home,
               WorkspaceSlot.bottom(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .bottom(anchor: current)
            }
            return nil
        case .beforeCurrent, .afterCurrent:
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
    func move(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot? {
        guard let slot = slot(for: id, section: section, in: sections, home: home) else { return nil }
        if slot == Self.top(for: id, section: section, in: sections, home: home) { return nil }
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
}

/// Registering new workspaces for placement, outside `WindowManager` (its
/// type budget): the rule for a window, and the pending placement that
/// `WindowManager.applyPendingPlacements` resolves once the daemon reports
/// the workspace.
@MainActor
enum NewWorkspacePlacements {
    /// `workspaces.newPlacement` for a new workspace of window `windowID`
    /// (nil: the window reconcile gives it, the most recent open one), with
    /// the workspace that window shows now. Read it at the request, before
    /// any hop and before the claim selects the new workspace. A window
    /// showing a top page (Home, Chats, a pinned page) selects that page's row
    /// in its sidebar, not a workspace's, so it has no current workspace: the
    /// one it showed last is not the one the person sees selected. The create
    /// sends the rule (`WorkspaceCreation`, `CreateWorkspaceRequest.current`), so
    /// the daemon places the new row against the same workspace, or none.
    static func rule(for windowID: String?, in windows: WindowManager) -> NewWorkspaceDefaultSlot {
        let placement = windows.services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback
        let state = (windowID ?? windows.registry.value.mostRecentOpen()).flatMap { windows.states[$0] }
        return NewWorkspaceDefaultSlot(placement: placement, current: state?.page == nil ? state?.workspaceID : nil)
    }

    /// Places workspace `id` at `slot`, else by `byDefault`, in window
    /// `windowID` (nil: the window that lists it): now when it is mirrored,
    /// else once the daemon reports it. `then` runs after, with the sidebar.
    static func expect(_ id: String, in windowID: String?, slot: WorkspaceSlot? = nil, byDefault: NewWorkspaceDefaultSlot?,
                       then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil, windows: WindowManager) {
        guard slot != nil || byDefault != nil || then != nil else { return }
        switch anchor(slot: slot, byDefault: byDefault, home: home(windows.services.machines)) {
        // Only a daemon that places the create by the rule puts it in the group (`sending` arms it).
        case let anchor? where anchor.isGroupAnchor: windows.newPlacements.groupAnchors[id] = anchor
        case let anchor?: windows.newPlacements.anchors[id] = anchor
        case nil: break
        }
        if windows.pendingPlacements[id] == nil { windows.pendingPlacementOrder.append(id) }
        windows.pendingPlacements[id] = PendingPlacement(window: windowID, slot: slot, byDefault: byDefault, then: then)
        if windows.services.machines.workspace(id: id) != nil { windows.applyPendingPlacements(live: [id]) }
    }

    /// `rule` when `connection`'s daemon places a create by it (`workspace-create-current-v1`), recording
    /// `key` in `ledger`'s ``Ledger/placedByDaemon``; nil for an older daemon, which
    /// ignores the fields, or with no ledger to record it in, so the app still sends its own placement afterwards.
    static func sending(_ rule: NewWorkspaceDefaultSlot?, key: WorkspaceKey, on connection: DaemonConnection,
                        ledger: Ledger?) async -> NewWorkspaceDefaultSlot? {
        guard let rule, let ledger else { return nil }
        // Read before the create goes out: the window places the workspace only once the daemon lists it.
        guard await connection.identity?.supports(DaemonCapability.workspaceCreateCurrent.rawValue) == true else { return nil }
        ledger.placedByDaemon.insert(key.rawValue)
        if let anchor = ledger.groupAnchors.removeValue(forKey: key.rawValue) { ledger.anchors[key.rawValue] = anchor }
        return rule
    }

    /// Drops what a create that ended without its workspace left for it.
    static func forget(_ id: String, windows: WindowManager) {
        windows.pendingPlacements[id] = nil
        windows.pendingPlacementOrder.removeAll { $0 == id }
        windows.newPlacements.placedByDaemon.remove(id)
        windows.newPlacements.anchors[id] = nil
        windows.newPlacements.groupAnchors[id] = nil
    }

    /// The neighbour of a new workspace placed at `slot`, else by `byDefault`: right before or after
    /// the window's current workspace (not Home), or the one New Workspace Above or Below names; under
    /// `top` / `bottom`, first / last in its group when it is in one (``NewWorkspaceDefaultSlot``'s rule).
    static func anchor(slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?, home: String?) -> SidebarDocSections.UnplacedAnchor? {
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
        case .beforeCurrent: return .before(current)
        case .afterCurrent: return .after(current)
        case .top: return .firstInGroupOf(current)
        case .bottom: return .lastInGroupOf(current)
        }
    }


    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }

    /// What these keep for each new workspace between its create and the
    /// sidebar placing it; one per `WindowManager` (`newPlacements`).
    @MainActor
    final class Ledger {
        /// New workspaces whose create sent the rule (`WorkspaceCreation`, `CreateWorkspaceRequest.current`):
        /// this Mac's daemon placed them at their slot in the commit that made them, under every value, so
        /// `applyPendingPlacements` sends no second write for them (a second state change and render).
        var placedByDaemon: Set<String> = []

        /// The neighbour each new workspace lists beside until the sidebar document places it
        /// (`SidebarDocSections.unplacedAnchor`), where the daemon's create puts it. Dropped once the
        /// document places the workspace or it is gone (`unplacedAnchor(of:machines:)`); a create still on its way
        /// (sent, its workspace not listed yet: ``placedByDaemon``) keeps its own.
        var anchors: [String: SidebarDocSections.UnplacedAnchor] = [:]
        /// `top` / `bottom` group anchors, armed into `anchors` once the create sends the rule (`sending`).
        var groupAnchors: [String: SidebarDocSections.UnplacedAnchor] = [:]

        /// The neighbour `workspace` lists beside while the document does not place it; prunes the ones placed or gone. A
        /// create still on its way (a terminal, command or agent workspace the daemon has not listed yet) keeps its anchor.
        func unplacedAnchor(of workspace: WorkspaceModel, machines: MachineRegistry) -> SidebarDocSections.UnplacedAnchor? {
            guard !anchors.isEmpty else { return nil }
            if anchors.count > 16 {
                anchors = anchors.filter { id, _ in
                    SidebarDocWiring.item(workspace: id, machines) == nil && (machines.workspace(id: id) != nil || placedByDaemon.contains(id))
                }
            }
            return anchors[workspace.id]
        }
    }

    /// The index a group formed for a new workspace takes (`createGroup`'s `index`, New Workspace in
    /// New Group): first under `workspaces.newPlacement` `top` (the default), else last (`Int.max`).
    /// The same rule as the Chief's subagent groups (`new_group_index` in optchat-chief workspaces.rs).
    static func newGroupIndex(_ services: AppServices) -> Int {
        newGroupIndex(for: services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback)
    }

    static func newGroupIndex(for placement: NewWorkspacePlacement) -> Int { placement == .top ? 0 : .max }
}
