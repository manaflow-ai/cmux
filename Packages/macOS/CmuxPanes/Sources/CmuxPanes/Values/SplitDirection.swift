public import Bonsplit

/// Split direction for backwards compatibility with old API.
public enum SplitDirection: Sendable {
    /// Insert the new pane to the left of the source pane.
    case left
    /// Insert the new pane to the right of the source pane.
    case right
    /// Insert the new pane above the source pane.
    case up
    /// Insert the new pane below the source pane.
    case down

    /// Whether the split divides space horizontally (left/right).
    public var isHorizontal: Bool {
        self == .left || self == .right
    }

    /// The Bonsplit orientation for the new split.
    public var orientation: SplitOrientation {
        isHorizontal ? .horizontal : .vertical
    }

    /// If true, insert the new pane on the "first" side (left/top).
    /// If false, insert on the "second" side (right/bottom).
    public var insertFirst: Bool {
        self == .left || self == .up
    }
}
