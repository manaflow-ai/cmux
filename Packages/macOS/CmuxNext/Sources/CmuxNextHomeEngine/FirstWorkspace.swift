public import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextWakeups
import Observation

/// Whether launch gives the tree its first workspace (`WindowManager.restore`, `FirstWorkspaceLaunch`).
public enum FirstWorkspace {
    /// The Home workspace a first launch lands on (`HomeTunables.launchIntoHome`, `FirstWorkspaceLaunch`),
    /// or nil to make a New Tab workspace: the switch is off, Home is classic, or Home has no workspace yet.
    public static func landing(launchIntoHome: Bool, classic: Bool, home: String?) -> String? {
        launchIntoHome && !classic ? home : nil
    }

    /// `landing` once the store lists the Home workspace `ensure_home` named (`ensured`): a fresh
    /// store's snapshot can lag that reply, and on the very first launch landing must not depend on
    /// which came first. `home` reads the listed workspace's id; it is waited for at most `within`,
    /// then the launch makes a New Tab workspace as before.
    @MainActor
    public static func landing(launchIntoHome: Bool, classic: Bool, ensured: Bool, within deadline: Duration = .seconds(3),
                               home: @escaping @MainActor @Sendable () -> String?) async -> String? {
        guard launchIntoHome, !classic, ensured else { return nil }
        if let listed = home() { return listed }
        let expired = DeadlineFlag()
        let timer = DemandTimer(owner: "first-workspace.home")
        timer.schedule(after: deadline) { @MainActor in expired.passed = true }
        defer { timer.cancel() }
        for await (listed, passed) in ObservationStream({ (home(), expired.passed) }) {
            if let listed { return listed }
            if passed { return nil }
        }
        return nil
    }

    /// A tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    /// `home` is the workspace `ensure_home` named: Home even while the tree
    /// does not report its kind yet (a fresh store's first snapshot).
    public static func isNeeded(_ workspaces: [WorkspaceModel], leftover: [String], home: ResourceID? = nil) -> Bool {
        !workspaces.contains { workspace in
            !leftover.contains(workspace.id) && !workspace.ephemeral && workspace.kind != "home"
                && (home == nil || workspace.resourceID != home)
        }
    }
}

/// Set when `FirstWorkspace.landing`'s deadline passes, so its observation ends.
@MainActor @Observable
final class DeadlineFlag {
    var passed = false
}
