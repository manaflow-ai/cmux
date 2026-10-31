import CmuxNextActions
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
            guard isServed else { return unserved(intent, DaemonCapability.workspaceGroupPin) }
            send("update-personal-group", intent, held: true) { try await $0.state.updateWorkspaceGroup(group.rawValue, pinned: pinned) }
            return true
        case let .setGroupIcon(group, icon):
            guard bridge.statePersonal, home.supports(DaemonCapability.workspaceGroupIcon.rawValue) else {
                return unserved(intent, DaemonCapability.workspaceGroupIcon)
            }
            let update: FieldUpdate<String> = icon.map { .set($0) } ?? .clear
            send("update-personal-group", intent, held: true) { try await $0.state.updateWorkspaceGroup(group.rawValue, icon: update) }
            return true
        case let .closeGroup(group):
            guard isServed, let pinned = bridge.model.group(group)?.isPinned else { return false }
            // The personal group: a sidebar-document row names its item (`itm_g_<id>`).
            let id = PersonalStore.legacyGroupID(item: group.rawValue)?.rawValue ?? group.rawValue
            // The group's rows are the bridge's close edit (`SidebarIntent.closeGroup`); this write only reports.
            if pinned {
                send("update-personal-group", intent, held: false) { try await $0.state.updateWorkspaceGroup(id, collapsed: true) }
            } else {
                send("delete-personal-group", intent, held: false) { try await $0.state.deleteWorkspaceGroup(id) }
            }
            return false
        default:
            return false
        }
    }

    /// A pin or icon change the home daemon cannot take: the group shows as it was, and the person sees why (#26382).
    private func unserved(_ intent: SidebarIntent, _ capability: DaemonCapability) -> Bool {
        let reason = bridge.statePersonal ? RefusalStrings.needsDaemonCapability(capability.rawValue) : home.personalStateUnavailableReason
        bridge.saveFailed(intent)(ActionWorkFailure(reason))
        return true
    }

    /// One home-daemon request for `intent`. `held`: the rows show `intent` now and hold it until the
    /// home store has it (a pending edit, #26382). A failure re-syncs the sidebar and says why.
    private func send(_ label: String, _ intent: SidebarIntent, held: Bool, _ body: @escaping DaemonCommandBody) {
        bridge.rows.send(label, edit: held ? bridge.rows.edits.add(intent) : nil, on: home, failed: bridge.saveFailed(intent), body)
    }
}
