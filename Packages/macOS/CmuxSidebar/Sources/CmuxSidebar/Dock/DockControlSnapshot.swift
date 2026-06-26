/// The per-control presentation value a Dock control projects for rendering.
///
/// A pure, immutable snapshot derived from a Dock control's runtime: the
/// stable `id`, the display `title`, the `command` shown under it, and the
/// optional `requestedHeight` the layout honors as a fixed terminal height.
/// The store projects one of these per control and the Dock views render from
/// them, so views never reach into live control runtime state.
public struct DockControlSnapshot: Identifiable, Sendable {
    /// Stable identifier of the control this snapshot represents.
    public let id: String
    /// Display title shown in the control's header.
    public let title: String
    /// Command string shown beneath the title.
    public let command: String
    /// Fixed terminal height the layout honors, or `nil` to size flexibly.
    public let requestedHeight: Double?

    /// Creates a Dock control snapshot.
    public init(id: String, title: String, command: String, requestedHeight: Double?) {
        self.id = id
        self.title = title
        self.command = command
        self.requestedHeight = requestedHeight
    }
}
