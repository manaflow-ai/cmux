public import AppKit

/// Whether a split-view divider hit resizes left/right (a vertical split view's
/// side-by-side divider) or up/down (a horizontal split view's stacked divider).
///
/// Carries the matching ``cursor`` so a host view can set the resize cursor
/// directly from the hit result without re-deriving the orientation.
public enum DividerCursorKind: Equatable, Sendable {
    /// A vertical split view's side-by-side divider; resizes left/right.
    case vertical
    /// A horizontal split view's stacked divider; resizes up/down.
    case horizontal

    /// The AppKit resize cursor matching this divider orientation.
    public var cursor: NSCursor {
        switch self {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        }
    }
}

/// The result of hit-testing a window point against an `NSSplitView` divider
/// tree: which orientation of divider was hit and whether the hit landed inside
/// a caller-designated hosted-content subtree.
///
/// `isInHostedContent` is computed by the detector against a `relativeTo:` view
/// the caller supplies (for the browser window portal, its WebKit-hosting host
/// view), so the package stays agnostic about what that subtree means; the
/// caller uses the flag to decide whether to pass the event through to the app
/// layout or treat it as hosted-content-internal.
public struct SplitDividerHit: Equatable, Sendable {
    /// The orientation of the divider that was hit, and its resize cursor.
    public let kind: DividerCursorKind

    /// Whether the hit divider's split view descends from the caller's
    /// hosted-content reference view.
    public let isInHostedContent: Bool

    /// Creates a divider hit result.
    /// - Parameters:
    ///   - kind: The divider orientation (and resize cursor) that was hit.
    ///   - isInHostedContent: Whether the hit landed in the caller's hosted
    ///     content subtree.
    public init(kind: DividerCursorKind, isInHostedContent: Bool) {
        self.kind = kind
        self.isInHostedContent = isInHostedContent
    }
}

/// Recursively hit-tests a window-space point against an `NSSplitView` divider
/// tree, returning the first divider whose expanded hit rect contains the point.
///
/// This is the static geometry pass behind the browser window portal's pointer
/// routing: each split view's divider rect is built from its arranged subviews'
/// frames (with a small expansion so a near-collapsed pane's divider stays
/// grabbable), converted into the split view's own coordinates, and tested
/// against the point. The walk descends into all subviews (reversed, so the
/// front-most split wins) so nested split views are included. The traversal is
/// pure geometry; the only host-specific input is the `relativeTo:` view used to
/// compute ``SplitDividerHit/isInHostedContent``.
public struct SplitDividerHitDetector {
    /// Creates a detector. The detector holds no state; it is a value type so
    /// callers can construct it inline at each hit-test.
    public init() {}

    /// Hit-tests `windowPoint` against the divider tree rooted at `view`.
    ///
    /// Hidden subtrees are skipped. For each `NSSplitView` whose bounds contain
    /// the point, every divider between consecutive arranged subviews is tested
    /// (expanded by 5 points) when at least one neighbour has a non-trivial
    /// extent along the split axis. The first containing divider wins, searching
    /// subviews front-to-back.
    /// - Parameters:
    ///   - windowPoint: The point to test, in window coordinates.
    ///   - view: The root view to traverse (typically the portal's divider
    ///     search root or the window's content view).
    ///   - hostView: The reference view used to compute
    ///     ``SplitDividerHit/isInHostedContent`` via `isDescendant(of:)`.
    /// - Returns: The first matching divider hit, or `nil` when no divider rect
    ///   contains the point.
    public func dividerHit(
        at windowPoint: NSPoint,
        in view: NSView,
        relativeTo hostView: NSView
    ) -> SplitDividerHit? {
        guard !view.isHidden else { return nil }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                let expansion: CGFloat = 5
                let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
                for dividerIndex in 0..<dividerCount {
                    let first = splitView.arrangedSubviews[dividerIndex].frame
                    let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                    let thickness = splitView.dividerThickness
                    let dividerRect: NSRect
                    if splitView.isVertical {
                        // Keep divider hit-testing active even when one side is nearly collapsed,
                        // so users can drag the divider back out from the border.
                        // But ignore transient states where both panes are effectively 0-width.
                        guard first.width > 1 || second.width > 1 else { continue }
                        let x = max(0, first.maxX)
                        dividerRect = NSRect(
                            x: x,
                            y: 0,
                            width: thickness,
                            height: splitView.bounds.height
                        )
                    } else {
                        // Same behavior for horizontal splits with a near-zero-height pane.
                        guard first.height > 1 || second.height > 1 else { continue }
                        let y = max(0, first.maxY)
                        dividerRect = NSRect(
                            x: 0,
                            y: y,
                            width: splitView.bounds.width,
                            height: thickness
                        )
                    }
                    let expanded = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expanded.contains(pointInSplit) {
                        return SplitDividerHit(
                            kind: splitView.isVertical ? .vertical : .horizontal,
                            isInHostedContent: splitView.isDescendant(of: hostView)
                        )
                    }
                }
            }
        }

        for subview in view.subviews.reversed() {
            if let hit = dividerHit(at: windowPoint, in: subview, relativeTo: hostView) {
                return hit
            }
        }

        return nil
    }
}
