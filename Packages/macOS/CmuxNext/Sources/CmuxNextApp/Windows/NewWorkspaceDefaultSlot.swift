import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

typealias NewWorkspaceDefaultSlot = CmuxNextBridge.NewWorkspaceDefaultSlot

extension NewWorkspaceDefaultSlot {
    /// Whether a window's rows built at `rowsAt` (the document's `shownChanges` then; nil: not built from its
    /// projection) are behind the sidebar document: its drawn projection is behind its version, or the window's
    /// rows pass has not run since the projection changed (a cold or updated layout a hop before its rows show).
    static func layoutCatchingUp(rowsAt: UInt64? = nil) -> Bool {
        guard let store = SidebarDocStore.current, store.isActive else { return false }
        return store.shown == nil || store.shownVersion != store.version || rowsAt != store.shownChanges
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
        let window = windowID ?? windows.registry.value.mostRecentOpen()
        let state = window.flatMap { windows.states[$0] }
        let current = state?.page == nil ? state?.workspaceID : nil
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
        await ledger?.sending(rule, key: key, on: connection)
    }

    /// Drops what a create that ended without its workspace left for it.
    static func forget(_ id: String, windows: WindowManager) {
        windows.pendingPlacements[id] = nil
        windows.pendingPlacementOrder.removeAll { $0 == id }
        windows.newPlacements.forget(id)
    }

    static func anchor(slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot?, home: String?) -> SidebarDocSections.UnplacedAnchor? {
        NewWorkspaceDefaultSlot.anchor(slot: slot, byDefault: byDefault, home: home)
    }

    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }

    typealias Ledger = WorkspacePlacementLedger

    /// The index a group formed for a new workspace takes (`createGroup`'s `index`, New Workspace in
    /// New Group): first under `workspaces.newPlacement` `top` (the default), else last (`Int.max`).
    /// The same rule as the Chief's subagent groups (`new_group_index` in optchat-chief workspaces.rs).
    static func newGroupIndex(_ services: AppServices) -> Int {
        newGroupIndex(for: services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback)
    }

    static func newGroupIndex(for placement: NewWorkspacePlacement) -> Int { placement == .top ? 0 : .max }
}
