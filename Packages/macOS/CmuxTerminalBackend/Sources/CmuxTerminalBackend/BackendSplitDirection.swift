/// User-facing direction for placing or resizing a canonical pane split.
public enum BackendSplitDirection: String, Codable, Equatable, Sendable {
    /// Place the new pane to the left, or address the horizontal divider on a pane's left.
    case left

    /// Place the new pane to the right, or address the horizontal divider on a pane's right.
    case right

    /// Place the new pane above, or address the vertical divider above a pane.
    case up

    /// Place the new pane below, or address the vertical divider below a pane.
    case down
}
