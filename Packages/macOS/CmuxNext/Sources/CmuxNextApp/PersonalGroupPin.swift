import CmuxNextDaemon
import CmuxNextSidebar

/// Pinned (saved) personal workspace groups on the home session
/// (`workspace-group-pin-v1`), and the group icon (`workspace-group-icon-v1`).
/// Pin and Unpin write the group's pin; Set and Remove Group Icon its icon. Close
/// All Workspaces in Group then decides the group's fate: a pinned group
/// stays, empty and collapsed; an unpinned one goes with its workspaces
/// (`SidebarIntent.closeGroup`), so it does not come back empty on the
/// next sync. A home daemon without the capability keeps groups as they are.
@MainActor
struct PersonalGroupPin {
    let bridge: SidebarBridge

    private var home: DaemonService { bridge.services.machines.local }
    private var isServed: Bool { bridge.statePersonal && home.supports(DaemonCapability.workspaceGroupPin.rawValue) }

    /// Handles a pin change (true). For a group close it sends the group's
    /// write and returns false, so the bridge still closes the workspaces.
    func handle(_ intent: SidebarIntent) -> Bool {
        switch intent {
        case let .setGroupPinned(group, pinned):
            guard isServed else {
                bridge.resync()
                return true
            }
            bridge.model.apply(intent)
            send("update-personal-group") { try await $0.state.updateWorkspaceGroup(group.rawValue, pinned: pinned) }
            return true
        case let .setGroupIcon(group, icon):
            guard bridge.statePersonal, home.supports(DaemonCapability.workspaceGroupIcon.rawValue) else {
                bridge.resync()
                return true
            }
            bridge.model.apply(intent)
            let update: FieldUpdate<String> = icon.map { .set($0) } ?? .clear
            send("update-personal-group") { try await $0.state.updateWorkspaceGroup(group.rawValue, icon: update) }
            return true
        case let .closeGroup(group):
            if let pinned = bridge.model.group(group)?.isPinned { closeEmptied(group, pinned: pinned) }
            return false
        default:
            return false
        }
    }

    /// The write of a group whose workspaces all closed (Close Group, or a selection's close that emptied it after its rows
    /// left the sidebar, `WorkspaceSelectionClose`): a pinned group stays, folded; an unpinned one goes (recorded, so
    /// Reopen Closed and the close's Undo form it again).
    func closeEmptied(_ group: GroupID, pinned: Bool) {
        guard isServed else { return }
        // The personal group: a sidebar-document row names its item (`itm_g_<id>`).
        let id = PersonalStore.legacyGroupID(item: group.rawValue)?.rawValue ?? group.rawValue
        if pinned { return send("update-personal-group") { try await $0.state.updateWorkspaceGroup(id, collapsed: true) } }
        send("delete-personal-group") { try await $0.state.deleteWorkspaceGroup(id) }
    }

    /// One home-daemon request; a failure re-syncs the sidebar.
    private func send(_ label: String, _ body: @escaping DaemonCommandBody) {
        let home = home, bridge = bridge
        Task {
            if await home.request(label, body) == nil { bridge.resync() }
        }
    }
}
