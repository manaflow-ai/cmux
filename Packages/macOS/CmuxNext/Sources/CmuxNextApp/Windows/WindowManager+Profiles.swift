import CmuxNextDaemon
import Foundation
import Observation

// Which profile each window shows (plans/cmux-next/data-model.md 4). The
// profile is the window's own state (`WindowState.profileID`, persisted in
// the personal projection); membership stays `WindowRegistry`'s. A switch
// changes only what the window lists and shows, in one main-actor turn:
// terminals keep running in the daemon and hidden surfaces take the normal
// hidden-tab path, so nothing restarts or flashes.
extension WindowManager {
    /// Shows `profile` in `state`'s window: the workspaces the window holds
    /// in it (the last one shown there is selected), else the profile's
    /// workspaces no open window showing that profile holds, else a new
    /// workspace created in it.
    func switchProfile(_ profile: ProfileID, in state: WindowState) {
        guard profile != state.profileID else { return }
        let machines = services.machines
        let members = registry.members(of: state.id)
        var visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        if visible.isEmpty {
            let adoptable = adoptableWorkspaces(in: profile, for: state.id)
            if !adoptable.isEmpty {
                transition { $0.move(adoptable, to: state.id) }
                visible = adoptable
            }
        }
        guard !visible.isEmpty else {
            // Nothing to show there yet: the window enters the profile with
            // a new workspace (no empty window, REWRITE.md round 1). It is
            // claimed before the create command, so the switch shows it as
            // soon as the daemon mirrors it.
            state.enterProfile(profile)
            recordSaver.stateDidChange(state)
            Task { [services] in await createWorkspace(into: state.id); withExtendedLifetime(services) {} }
            return
        }
        let remembered = state.profileWorkspaces[profile].flatMap { visible.contains($0) ? $0 : nil }
        state.enterProfile(profile)
        select(remembered ?? visible.first, in: state)
    }

    /// Next (+1) or previous (-1) profile of the local daemon, clamped at
    /// the ends. Returns false when there is none that way.
    @discardableResult
    func stepProfile(by delta: Int, in state: WindowState) -> Bool {
        let order = services.machines.local.store.profileIDs
        guard let index = order.firstIndex(of: state.profileID) ?? order.indices.first else { return false }
        let target = min(max(index + delta, 0), order.count - 1)
        guard target != index else { return false }
        switchProfile(order[target], in: state)
        return true
    }

    /// Workspaces of `profile` on every session that no open window
    /// currently showing `profile` holds (hidden in other windows, in the
    /// closed window, or not placed yet), in daemon order.
    func adoptableWorkspaces(in profile: ProfileID, for windowID: String) -> [String] {
        let value = registry.value
        let shownElsewhere = Set(value.openWindows.filter { window in
            window.id != windowID && states[window.id]?.profileID == profile
        }.flatMap(\.workspaceIDs))
        let machines = services.machines
        return machines.daemons.flatMap { WindowProfiles.workspaces(of: $0, in: profile, machines: machines) }
            .map(\.id).filter { !shownElsewhere.contains($0) }
    }

    /// The profile a workspace created for `windowID` is born in: that
    /// window's, else the active window's, else `default`.
    func profileForNewWorkspace(window windowID: String?) -> ProfileID {
        windowID.flatMap { states[$0]?.profileID } ?? active?.state.profileID ?? .defaultProfile
    }

    /// Selecting a workspace of another room (palette, CLI, a
    /// notification) shows that room in the window first.
    func enterProfile(of workspaceID: String, in state: WindowState) {
        guard let room = WindowProfiles.room(of: workspaceID, current: state.profileID, machines: services.machines) else { return }
        state.enterProfile(room)
    }
}

extension DaemonStore {
    /// Returns once this store holds room `id`, or the connection changed.
    /// A command's reply comes before the mirror: rooms arrive through
    /// `personal-changed` and a resync. Event-driven: it observes the store.
    func mirrored(profile id: ProfileID) async {
        guard profile(id) == nil else { return }
        let state = connectionState
        for await done in Observations({ self.profile(id) != nil || self.connectionState != state }) where done {
            return
        }
    }
}
