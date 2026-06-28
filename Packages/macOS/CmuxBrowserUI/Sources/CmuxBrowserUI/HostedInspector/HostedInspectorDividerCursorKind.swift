public import AppKit

/// The cursor shape shown over a hosted Web Inspector divider. Only the
/// vertical (left/right resize) orientation exists today; the type keeps the
/// orientation-to-cursor mapping in one place so the host view tracks which
/// cursor it has installed without inlining `NSCursor` choices.
public enum HostedInspectorDividerCursorKind: Equatable {
    /// A vertical divider dragged left/right to resize the inspector and page.
    case vertical

    /// The `NSCursor` to show for this divider orientation.
    public var cursor: NSCursor { .resizeLeftRight }
}
