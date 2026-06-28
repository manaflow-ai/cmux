/// The direction of a `workspace.action` single-slot reorder (`move_up` /
/// `move_down`), driving the app-side witness's index math (the legacy
/// `max(currentIndex - 1, 0)` / `min(currentIndex + 1, count - 1)`).
public enum ControlWorkspaceActionReorderDirection: Sendable, Equatable {
    /// Move the workspace up one slot (legacy `move_up`).
    case up
    /// Move the workspace down one slot (legacy `move_down`).
    case down
}
