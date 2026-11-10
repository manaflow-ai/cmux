public import CmuxNextCompat
public import Observation

/// Observable holder of the app's `WindowRegistry`, so each window's sidebar
/// re-filters when membership changes. Owned by the app's `WindowManager`, the
/// only writer.
@Observable
public final class WindowRegistryStore {
    public private(set) var value = WindowRegistry()
    /// Membership of windows drawn from the daemon's launch snapshot before
    /// the live registry is restored (`LaunchSnapshotWindow`);
    /// cleared by the restore (`clearProvisional`). Observed one window at a time: a write of window A's
    /// entry notifies only the readers of A's (`members(of: A)`), and a clear of an entry already empty
    /// notifies nobody. A plain dictionary property was one observed value: the restore's clear cancelled every
    /// tracker that had read any window's members since launch, 2.4-2.6 s of main thread on the launch after an update
    /// (cmuxterm-hq#6338, stack 2).
    public let provisional = ObservedMap<String, [String]>()
    /// True from the launch window until the saved windows are restored
    /// from the live tree: meanwhile sidebars show their saved rows
    /// (`SidebarSeed`).
    public var isLaunching = false
    /// Each workspace's window kind, observed one workspace at a time: true while an incognito window lists it or it is
    /// discarded with a closed one, false while a normal window lists it, nil while no window does. A sidebar row reads
    /// its own workspace's entry, never `value`, so a workspace made, closed or moved elsewhere maps no other row again
    /// (TYPING UNDER LOAD F6: every row read the whole registry).
    public let incognitoByWorkspace = ObservedMap<String, Bool>()
    /// The close-selection rule's state for the workspaces of every window: who opened which, and the pick after a
    /// close (`WindowCloseSelection`). One instance for all windows is safe: a workspace has one owner window
    /// (`WindowRegistry.owner(of:)`), so no relation of one window can be ended by a selection change of another.
    @ObservationIgnored public let closeSelection = WindowCloseSelection()
    /// The window that lists each workspace (`WindowRegistry.owner(of:)`), observed one workspace at a time: nil while
    /// no window lists it. An observer of ONE workspace (its link places, its shown name) reads its own entry, never
    /// `value`: a read of `value` there made one workspace made or closed wake one observer per workspace of the
    /// session (WORKSPACE LIST 800: 826 workspaces named again per list change, about 100 ms of main thread).
    public let ownerByWorkspace = ObservedMap<String, String>()
    /// The workspaces `incognitoByWorkspace` and `ownerByWorkspace` answer for.
    @ObservationIgnored private var answered: Set<String> = []

    public init() {}

    /// Whether window `id` is one the launch brings back (the launch window, or one of the `saved` windows the
    /// restore opens) while the launch runs. Only such a window stands in for its rows (saved rows, the connecting
    /// machines' loading bars) and shows in place. A window this run opens, also while the launch runs or after a
    /// restore that gave up (`isLaunching` stays set then), is new: it lists its own live rows from its first frame
    /// and opens like a new window (https://github.com/manaflow-ai/cmux/issues/38128).
    public func restoresSession(_ id: String, launchWindow: String?, saved: [String]?) -> Bool {
        isLaunching && (id == launchWindow || saved?.contains(id) == true)
    }

    /// Runs one transition; returns what it changed.
    @discardableResult
    public func apply(_ transition: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        var next = value
        let changes = transition(&next)
        if next != value {
            value = next
            refreshWorkspaceAnswers()
        }
        return changes
    }

    /// Drops every launch-snapshot membership (the restore): each window's readers hear only their own window's entry.
    public func clearProvisional() {
        for id in provisional.keys { provisional[id] = nil }
    }

    /// Workspaces window `id` lists, in order.
    public func members(of id: String) -> [String] { value.window(id)?.workspaceIDs ?? provisional[id] ?? [] }

    /// What closes read of this registry since the last `takeCloseWork()` (`WorkspaceCloseWork`).
    @ObservationIgnored public private(set) var closeWork = WorkspaceCloseWork()

    /// The counts since the last call; counts from zero again.
    public func takeCloseWork() -> WorkspaceCloseWork {
        defer { closeWork = WorkspaceCloseWork() }
        return closeWork
    }

    /// The windows a selection repair visits, counted in `closeWork`: every window, or window `only` alone. A close
    /// names its window: the rows it hides are that window's, and no other window lists them (one window owns a
    /// workspace, `WindowRegistry.violations`), so no other selection can change and no other list is read.
    public func repairs(only: String? = nil) -> [WindowRegistry.Window] {
        let windows = only.map { id in value.windows.filter { $0.id == id } } ?? value.windows
        closeWork.repairedWindows += windows.count
        closeWork.repairedIDs += windows.reduce(0) { $0 + $1.workspaceIDs.count }
        return windows
    }

    /// The ones of `ids` (a window's parked workspaces) that window `id` does not list, for its `showWorkspace` (one
    /// run, counted in `closeWork`): one lookup of the owner index for each, never a set of the window's whole list
    /// (826 ids per workspace switch and per close in the person's session). Its own list is searched only for an id
    /// another window lists first (a broken invariant, `WindowRegistry.violations`); a window not registered yet
    /// answers from its launch snapshot (`provisional`), as `members(of:)` does.
    public func unlisted(_ ids: some Sequence<String>, in id: String) -> Set<String> { // perf-hot: 0.01ms workspace-switch (O(parked))
        let registry = value
        let window = registry.window(id)
        let launch = window == nil ? Set(provisional[id] ?? []) : []
        var unlisted: Set<String> = []
        closeWork.showCalls += 1
        for workspace in ids {
            closeWork.shownIDs += 1
            let owner = registry.owner(of: workspace)
            if owner == id { continue }
            var listed = launch.contains(workspace)
            if let window, owner != nil {
                closeWork.shownIDs += window.workspaceIDs.count
                listed = window.workspaceIDs.contains(workspace)
            }
            if !listed { unlisted.insert(workspace) }
        }
        return unlisted
    }

    /// The window that lists `workspaceID` (`value.owner(of:)`); observes that workspace's entry only.
    public func owner(ofWorkspace workspaceID: String) -> String? { ownerByWorkspace[workspaceID] }

    /// Writes each workspace's window kind and owner: O(listed workspaces); only the entries that changed notify.
    private func refreshWorkspaceAnswers() {
        var answers: [String: Bool] = [:]
        var owners: [String: String] = [:]
        // The first window that lists a workspace owns it (`WindowRegistry.owner(of:)`).
        for window in value.windows {
            for id in window.workspaceIDs where answers[id] == nil {
                answers[id] = value.isIncognito(window.id)
                owners[id] = value.owner(of: id)
            }
        }
        for id in value.discarding { answers[id] = true }
        for id in answered {
            if answers[id] == nil { incognitoByWorkspace[id] = nil }
            if owners[id] == nil { ownerByWorkspace[id] = nil }
        }
        for (id, answer) in answers { incognitoByWorkspace[id] = answer }
        for (id, owner) in owners { ownerByWorkspace[id] = owner }
        answered = Set(answers.keys)
    }
}
