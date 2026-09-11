import CoreGraphics

/// A stateless change to the focused pane's share of a split.
public enum PaneSizeAdjustment: Sendable {
    /// Increases the focused pane's share.
    case grow
    /// Decreases the focused pane's share.
    case shrink

    var shareDeltaSign: CGFloat {
        switch self {
        case .grow:
            return 1
        case .shrink:
            return -1
        }
    }
}
