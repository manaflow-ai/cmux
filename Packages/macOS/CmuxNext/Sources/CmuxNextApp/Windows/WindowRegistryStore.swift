import CmuxNextCompat
import CmuxNextLayout
import Observation

/// Observable holder of the app's `WindowRegistry`, so each window's sidebar
/// re-filters when membership changes. Owned by `WindowManager`, the only
/// writer.
@Observable
final class WindowRegistryStore {
    private(set) var value = WindowRegistry()
    /// Membership of windows drawn from the daemon's launch snapshot before
    /// the live registry is restored (`LaunchSnapshotWindow`);
    /// cleared by the restore.
    var provisional: [String: [String]] = [:]
    /// True from the launch window until the saved windows are restored
    /// from the live tree: meanwhile sidebars show their saved rows
    /// (`SidebarSeed`).
    var isLaunching = false
    /// Each workspace's window kind, observed one workspace at a time (`WindowManager.isIncognito(workspace:)`): true
    /// while an incognito window lists it or it is discarded with a closed one, false while a normal window lists it,
    /// nil while no window does. A sidebar row reads its own workspace's entry, never `value`, so a workspace made,
    /// closed or moved in another window maps no other row again (TYPING UNDER LOAD F6: every row read the whole
    /// registry).
    let incognitoByWorkspace = ObservedMap<String, Bool>()
    /// The workspaces `incognitoByWorkspace` answers for.
    @ObservationIgnored private var answered: Set<String> = []

    /// Runs one transition; returns what it changed.
    @discardableResult
    func apply(_ transition: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        var next = value
        let changes = transition(&next)
        if next != value {
            value = next
            refreshIncognitoAnswers()
        }
        return changes
    }

    /// Writes each workspace's window kind: O(listed workspaces), and only the entries that changed notify.
    private func refreshIncognitoAnswers() {
        var answers: [String: Bool] = [:]
        // The first window that lists a workspace owns it (`WindowRegistry.owner(of:)`).
        for window in value.windows {
            for id in window.workspaceIDs where answers[id] == nil { answers[id] = value.isIncognito(window.id) }
        }
        for id in value.discarding { answers[id] = true }
        for id in answered where answers[id] == nil { incognitoByWorkspace[id] = nil }
        for (id, answer) in answers { incognitoByWorkspace[id] = answer }
        answered = Set(answers.keys)
    }

    /// Workspaces window `id` lists, in order.
    func members(of id: String) -> [String] { value.window(id)?.workspaceIDs ?? provisional[id] ?? [] }
}
