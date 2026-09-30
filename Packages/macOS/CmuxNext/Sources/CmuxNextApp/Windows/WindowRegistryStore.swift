import Observation

/// Observable holder of the app's `WindowRegistry`, so each window's sidebar
/// re-filters when membership changes. Owned by `WindowManager`, the only
/// writer.
@Observable
final class WindowRegistryStore {
    private(set) var value = WindowRegistry()

    /// Runs one transition; returns what it changed.
    @discardableResult
    func apply(_ transition: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        var next = value
        let changes = transition(&next)
        if next != value { value = next }
        return changes
    }

    /// Workspaces window `id` lists, in order.
    func members(of id: String) -> [String] { value.window(id)?.workspaceIDs ?? [] }
}
