public import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextWakeups
import Observation

extension Array where Element == WorkspaceModel {
    /// Whether launch gives the tree its first workspace (`WindowManager.restore`, `FirstWorkspaceLaunch`):
    /// a tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    /// `home` is the workspace `ensure_home` named: Home even while the tree
    /// does not report its kind yet (a fresh store's first snapshot).
    public func needsFirstWorkspace(leftover: [String], home: ResourceID? = nil) -> Bool {
        !contains { workspace in
            !leftover.contains(workspace.id) && !workspace.ephemeral && workspace.kind != "home"
                && (home == nil || workspace.resourceID != home)
        }
    }
}

/// Where a first launch lands (`FirstWorkspaceLaunch`): Home, the Chief's workspace, unless
/// Debug Settings > Home > First launch opens Home is off (`HomeTunables.launchIntoHome`) or Home
/// is classic; then the launch makes a New Tab workspace.
public struct FirstWorkspaceLanding: Sendable {
    public let launchIntoHome: Bool
    public let classic: Bool
    /// How long `home(ensured:listed:)` waits for the store to list Home.
    public let deadline: Duration

    public init(launchIntoHome: Bool, classic: Bool, deadline: Duration = .seconds(3)) {
        self.launchIntoHome = launchIntoHome
        self.classic = classic
        self.deadline = deadline
    }

    /// The Home workspace to land on, or nil to make a New Tab workspace (also while Home has
    /// no workspace).
    public func home(_ listed: String?) -> String? {
        launchIntoHome && !classic ? listed : nil
    }

    /// `home` once the store lists the Home workspace `ensure_home` named (`ensured`): a fresh
    /// store's snapshot can lag that reply, and on the very first launch landing must not depend on
    /// which came first. `listed` reads the listed workspace's id; it is waited for at most
    /// `deadline`, then the launch makes a New Tab workspace as before.
    @MainActor
    public func home(ensured: Bool, listed: @escaping @MainActor @Sendable () -> String?) async -> String? {
        guard launchIntoHome, !classic, ensured else { return nil }
        if let id = listed() { return id }
        let expired = DeadlineFlag()
        let timer = DemandTimer(owner: "first-workspace.home")
        timer.schedule(after: deadline) { @MainActor in expired.passed = true }
        defer { timer.cancel() }
        for await (id, passed) in ObservationStream({ (listed(), expired.passed) }) {
            if let id { return id }
            if passed { return nil }
        }
        return nil
    }
}

/// Set when `FirstWorkspaceLanding`'s deadline passes, so its observation ends.
@MainActor @Observable
final class DeadlineFlag {
    var passed = false
}
