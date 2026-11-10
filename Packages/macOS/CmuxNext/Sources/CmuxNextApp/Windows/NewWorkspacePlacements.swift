import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar

/// Registering new workspaces for placement, outside `WindowManager` (its
/// type budget): the rule for a window, and the pending placement that
/// `WindowManager.applyPendingPlacements` resolves once the daemon reports
/// the workspace.
@MainActor
enum NewWorkspacePlacements {
    /// `workspaces.newPlacement` for a new workspace of window `windowID` (nil: the window reconcile gives it, the most
    /// recent open one), with the workspace that window shows now: none under a top page such as Home, which parks the
    /// last one and keeps `workspaceID` (#32731). Read it before the claim selects the new workspace.
    static func rule(for windowID: String?, in windows: WindowManager) -> NewWorkspaceDefaultSlot {
        let placement = windows.services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementDefault
        let window = windowID ?? windows.registry.value.mostRecentOpen()
        let current = window.flatMap { windows.states[$0] }.flatMap { $0.page == nil ? $0.workspaceID : nil }
        let model = window.flatMap { windows.controller(for: $0)?.sidebar.model }
        let currentMachine = current.flatMap { id in
            model.map { shownInBand(id, layout: $0.layout, room: $0.activeProfileID?.rawValue,
                                   legacy: windows.services.sidebarLayout.unavailableReason != nil, machines: windows.services.machines) } == true
                ? nil : windows.services.machines.daemon(forWorkspace: id)?.machineID
        }
        return NewWorkspaceDefaultSlot(placement: placement, current: current, currentMachine: currentMachine, currentGaps: NewWorkspaceDefaultSlot.gaps(around: current, in: model?.sections))
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

    /// A new workspace's key, placed like Cmd-N's on any machine: a create with no slot of its own never lands at its daemon's.
    static func placedKey(in windows: WindowManager) -> WorkspaceKey { placedCreate(in: windows).key }

    /// ``placedKey(in:)`` with the rule it is placed by, for the create to send (`WorkspaceCreation`'s `placedBy`), so
    /// the daemon places it by the same rule against the same current workspace.
    static func placedCreate(in windows: WindowManager) -> (key: WorkspaceKey, rule: NewWorkspaceDefaultSlot) {
        let key = WorkspaceKey.generate(), byDefault = rule(for: nil, in: windows)
        expect(key.rawValue, in: nil, byDefault: byDefault, windows: windows)
        return (key, byDefault)
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

    typealias Ledger = WorkspacePlacementLedger

    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }

    /// The index a group formed for a new workspace takes (`createGroup`'s `index`, New Workspace in
    /// New Group): last (`Int.max`) only under `workspaces.newPlacement` `bottom`, else first: under
    /// `afterCurrent` (the default) a new workspace never goes to the sidebar's end (Leo 2026-11-06).
    static func newGroupIndex(_ services: AppServices) -> Int {
        newGroupIndex(for: services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementDefault)
    }

    static func newGroupIndex(for placement: NewWorkspacePlacement) -> Int { placement == .bottom ? .max : 0 }
}
