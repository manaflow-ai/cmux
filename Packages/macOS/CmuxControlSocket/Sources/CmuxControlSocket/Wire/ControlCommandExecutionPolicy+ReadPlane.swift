/// Read-plane classifications shared by the socket dispatcher, snapshot
/// publisher, and per-client backpressure limiter.
extension ControlCommandExecutionPolicy {
    /// v2 methods whose result can be served from the last main-actor-published
    /// immutable snapshot. A request may still fall back to a live resolution
    /// when no entry for its exact params has been published yet.
    public static let readSnapshotMethods: Set<String> = [
        "surface.list",
        "surface.current",
        "workspace.list",
        "workspace.current",
        "window.list",
        "window.current",
        "window.displays",
        "pane.list",
        "pane.surfaces",
        "system.identify",
        "system.tree",
        "system.top",
        "system.memory",
        "surface.read_text",
    ]

    /// v1/v2 polling names subject to a per-connection token bucket.
    public static let pollingMethods: Set<String> = [
        "system.top",
        "system.memory",
        "system.tree",
        "system.identify",
        "window.list",
        "window.current",
        "window.displays",
        "workspace.list",
        "workspace.current",
        "surface.list",
        "surface.current",
        "surface.read_text",
        "pane.list",
        "pane.surfaces",
        "list_windows",
        "current_window",
        "list_workspaces",
        "current_workspace",
        "list_surfaces",
        "read_screen",
    ]

    /// Whether a v2 method belongs to the published read plane.
    public static func servesFromPublishedReadSnapshot(method: String) -> Bool {
        readSnapshotMethods.contains(method)
    }
}
