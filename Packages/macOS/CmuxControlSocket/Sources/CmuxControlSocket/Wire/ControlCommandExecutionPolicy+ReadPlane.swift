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

    /// Expensive diagnostic/content reads subject to a per-connection bucket.
    ///
    /// Topology and identity reads also resolve targets for one-shot commands.
    /// A single tmux display-message/list-panes/split-window can fan out to
    /// arbitrarily many of those reads as workspace and pane counts grow.
    /// Charging them as polls can reject a mutation before it is even sent.
    /// Keep both v1 and v2 resolution reads outside this budget; snapshot
    /// eligibility above is independent of polling admission.
    public static let pollingMethods: Set<String> = [
        "system.top",
        "system.memory",
        "system.tree",
        "surface.read_text",
        "surface.read_selection",
        "read_screen",
    ]

    /// Whether a v2 method belongs to the published read plane.
    public static func servesFromPublishedReadSnapshot(method: String) -> Bool {
        readSnapshotMethods.contains(method)
    }
}
