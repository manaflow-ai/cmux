public import AppKit

/// Orientation of a split-view divider under the pointer, used to pick the
/// resize cursor when a portal-hosted view passes a divide-hit through to the
/// underlying `NSSplitView`.
public enum SplitDividerCursorKind: Equatable {
    case vertical
    case horizontal

    /// The resize cursor matching this divider's orientation.
    public var cursor: NSCursor {
        switch self {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        }
    }
}
