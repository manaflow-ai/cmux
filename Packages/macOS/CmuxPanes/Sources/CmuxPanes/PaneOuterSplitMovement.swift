public import Bonsplit

/// A direction in which the focused pane can be promoted to a new workspace
/// edge split.
public enum PaneOuterSplitMovement: CaseIterable, Hashable, Sendable {
    /// Promotes the pane to the left edge of the root split.
    case left
    /// Promotes the pane to the right edge of the root split.
    case right
    /// Promotes the pane to the top edge of the root split.
    case above
    /// Promotes the pane to the bottom edge of the root split.
    case below

    /// The Bonsplit orientation needed for this edge.
    public var orientation: SplitOrientation {
        switch self {
        case .left, .right: .horizontal
        case .above, .below: .vertical
        }
    }

    /// Whether the promoted pane belongs before the existing root tree.
    public var insertFirst: Bool {
        switch self {
        case .left, .above: true
        case .right, .below: false
        }
    }
}
