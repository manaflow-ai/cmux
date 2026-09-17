/// Why a pane's projection ended. Only a pane closed on purpose edits the machine's
/// layout; a workspace going away and a pane the app replaced itself never do.
enum SurfaceProjectionEndReason: Sendable {
    /// The pane was closed: its tab strip ×, a pane close, socket `surface.close`.
    case paneClosed
    /// The local workspace is going away (⌘⇧W, window close, quit, machine removal).
    case workspaceTeardown
    /// The catalog or a provider closed the pane itself (a placeholder a materialization
    /// replaced, the loser of an open race, the panes of a terminal that was just killed).
    case replaced
}
