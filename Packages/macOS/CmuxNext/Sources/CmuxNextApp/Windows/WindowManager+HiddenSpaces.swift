import CmuxNextDaemon

// Hidden-space hibernation (leo-workspace design/spaces.md, "Hibernation and the perf plan"): a space
// no window shows is hidden, and its workspaces hibernate on `workspaces.hibernation.hiddenSpaceMinutes`.
// Read once per hibernation pass (the planner's existing deadline); no timer or observer of its own.
extension WindowManager {
    /// The spaces the open windows show now.
    var shownSpaceIDs: Set<ProfileID> { Set(controllers.map(\.state.profileID)) }

    /// Whether a workspace's space is hidden: no open window shows any room it is in. Always false
    /// without rooms (a home daemon lacking `profiles-v1` has one implicit room every window shows)
    /// and for a workspace no session reports yet.
    func hiddenSpaceTest() -> (String) -> Bool {
        let machines = services.machines
        guard let membership = WindowProfiles.membership(machines) else { return { _ in false } }
        let shown = shownSpaceIDs
        return { id in WindowProfiles.qualified(id, machines: machines).map { membership.isHidden($0, shown: shown) } ?? false }
    }
}
