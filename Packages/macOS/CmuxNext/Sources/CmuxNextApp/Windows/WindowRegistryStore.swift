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

    /// Workspaces each registered window lists, by window id: the membership
    /// projection of `value`. Set only when a window's list changes, so a
    /// reader of membership (``members(of:)``: the control snapshot, each
    /// window's show inputs, the sidebars) does not wake on a key or order
    /// change (`WindowRegistry.recency`, every window switch) or a geometry
    /// capture, which change `value` but list the same workspaces.
    private(set) var membership: [String: [String]] = [:]

    /// Runs one transition; returns what it changed.
    @discardableResult
    func apply(_ transition: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        var next = value
        let changes = transition(&next)
        guard next != value else { return changes }
        // Equal arrays that share storage compare in O(1): a recency-only change costs nothing here.
        let relisted = next.windows != value.windows
        value = next
        if relisted {
            let listed = Dictionary(next.windows.map { ($0.id, $0.workspaceIDs) }, uniquingKeysWith: { first, _ in first })
            if listed != membership { membership = listed }
        }
        return changes
    }

    /// Workspaces window `id` lists, in order. Reads ``membership``, not `value`: a tracked
    /// caller hears membership changes only.
    func members(of id: String) -> [String] { membership[id] ?? provisional[id] ?? [] }
}
