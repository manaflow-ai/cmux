public import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextWakeups
public import CmuxNextWindowRules
import Observation

extension Array where Element == WorkspaceModel {
    /// Whether launch gives the tree its first workspace (`WindowManager.restore`, `FirstWorkspaceLaunch`):
    /// a tree with no workspace of the user's own gets one at launch.
    /// Leftover incognito and ephemeral workspaces do not count, nor does
    /// the store's home workspace, which exists from the first connect
    /// (`HomeService.ensureHomeWorkspace`) and holds only the Chief tab.
    /// `home` is the workspace `ensure_home` named: Home even while the tree
    /// does not report its kind yet (a fresh store's first snapshot).
    /// The daemon's recovery workspace does not count either: it holds terminal hosts an
    /// earlier daemon left running, not a workspace the person made, and counting it made the
    /// first contact with classic skip the import prompt (classic handoff B16). The daemon marks
    /// it (`WorkspaceModel.recovered`, `workspace-recovered-v1`); a daemon without the mark is
    /// matched by the workspace's name.
    public func needsFirstWorkspace(leftover: [String], home: ResourceID? = nil) -> Bool {
        !contains { workspace in
            !leftover.contains(workspace.id) && !workspace.ephemeral && workspace.kind != "home"
                && (home == nil || workspace.resourceID != home)
                && !(workspace.recovered ?? recoveredTerminalsNames.contains(workspace.name))
        }
    }
}

/// The names cmux-tui gives the workspace it recovers orphaned terminal hosts into, in each
/// language it ships (`cmux-tui-util/src/terminal_respawn_text.rs`,
/// `cmux-tui/src/localization/terminal_respawn.rs`): the fallback for a daemon that sends no
/// `recovered` mark.
private let recoveredTerminalsNames: Set<String> = ["Recovered terminals", "復元されたターミナル"]

/// What a launch opens first (`FirstWorkspaceLaunch`), as the launch rule (cmux-window-rules
/// `launch::fresh_landing`) answers: the rule decides Home, a New Tab workspace, or nothing yet;
/// this asks it again on each change while it waits, and waits for the store to list Home.
public struct FirstWorkspaceLanding: Sendable {
    /// What the launch opens: Home's workspace, or a New Tab workspace it makes.
    public enum Opens: Equatable, Sendable {
        case home(String)
        case newTab
    }

    /// How long `home(listed:)` waits for the store to list Home.
    public let deadline: Duration

    public init(deadline: Duration = .seconds(3)) {
        self.deadline = deadline
    }

    /// What the launch opens before the saved windows, or nil when it opens nothing fresh (the saved windows
    /// decide) or the launch ended while waiting. `facts` reads the rule's facts and whether an `ensure_home` is in
    /// flight (the fallback for a pinned FFI without the op); it is read again on each change while the rule says
    /// to wait for Home, which ends once `ensure_home` answers or the daemon can no longer ensure Home: no timer.
    /// A Home that the store does not list by `deadline` makes a New Tab workspace, as before the rule.
    @MainActor
    public func opens(_ facts: @escaping @MainActor @Sendable () -> (WindowRules.FreshFacts, ensureInFlight: Bool),
                      listed: @escaping @MainActor @Sendable () -> String?) async -> Opens? {
        for await (read, inFlight) in ObservationStream(facts) {
            switch WindowRules().freshLanding(read, ensureInFlight: inFlight) {
            case .waitForHome: continue
            case .saved: return nil
            case .newTab: return .newTab
            case .home: return await home(listed: listed).map(Opens.home) ?? .newTab
            }
        }
        return nil
    }

    /// What the launch window opens when no saved window is open (#31514) and the launch made no first
    /// workspace: the tree has one of the person's own, and Home is ensured (`opens` waited for it).
    public func opensWithNoSavedWindowOpen(classicHome: Bool, homeEnsured: Bool) -> Opens? {
        let facts = WindowRules.FreshFacts(emptyTree: false, noSavedWindowOpen: true, classicHome: classicHome,
                                           homeEnsured: homeEnsured, homeNotEnsuredYet: false)
        return WindowRules().freshLanding(facts, ensureInFlight: false) == .newTab ? .newTab : nil
    }

    /// The Home workspace once the store lists it: a fresh store's snapshot can lag the
    /// `ensure_home` reply, and on the very first launch landing must not depend on which came
    /// first. `listed` reads the listed workspace's id; it is waited for at most `deadline`, then
    /// nil, and the launch makes a New Tab workspace as before.
    @MainActor
    public func home(listed: @escaping @MainActor @Sendable () -> String?) async -> String? {
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
