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
    /// The workspaces `incognitoByWorkspace` answers for.
    @ObservationIgnored private var answered: Set<String> = []

    public init() {}

    /// Runs one transition; returns what it changed.
    @discardableResult
    public func apply(_ transition: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        var next = value
        let changes = transition(&next)
        if next != value {
            value = next
            refreshIncognitoAnswers()
        }
        return changes
    }

    /// Drops every launch-snapshot membership (the restore): each window's readers hear only their own window's entry.
    public func clearProvisional() {
        for id in provisional.keys { provisional[id] = nil }
    }

    /// Workspaces window `id` lists, in order.
    public func members(of id: String) -> [String] { value.window(id)?.workspaceIDs ?? provisional[id] ?? [] }

    /// Writes each workspace's window kind: O(listed workspaces); only the entries that changed notify.
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
}
