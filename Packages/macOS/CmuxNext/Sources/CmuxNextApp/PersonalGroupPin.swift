import CmuxNextDaemon
import CmuxNextSidebar

/// Pinned (saved) personal workspace groups on the home session
/// (`workspace-group-pin-v1`). Pin and Unpin write the group's pin. Close
/// All Workspaces in Group then decides the group's fate: a pinned group
/// stays, empty and collapsed; an unpinned one goes with its workspaces
/// (`SidebarIntent.closeGroup`), so it does not come back empty on the
/// next sync. A home daemon without the capability keeps groups as they are.
@MainActor
struct PersonalGroupPin {
    let bridge: SidebarBridge

    private var home: DaemonService { bridge.services.machines.local }
    private var isServed: Bool { bridge.statePersonal && home.supports(DaemonCapabilities.shared.workspaceGroupPin) }

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
        case let .closeGroup(group):
            guard isServed, let pinned = bridge.model.group(group)?.isPinned else { return false }
            let id = group.rawValue
            if pinned {
                send("update-personal-group") { try await $0.state.updateWorkspaceGroup(id, collapsed: true) }
            } else {
                send("delete-personal-group") { try await $0.state.deleteWorkspaceGroup(id) }
            }
            return false
        default:
            return false
        }
    }

    /// One home-daemon request; a failure re-syncs the sidebar.
    private func send(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        let home = home, bridge = bridge
        Task {
            if await home.request(label, body) == nil { bridge.resync() }
        }
    }
}
