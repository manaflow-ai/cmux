public import AppKit

/// A window-space region occupied by a single `NSSplitView` divider.
///
/// `rectInWindow` is the divider's rectangle converted into the window's
/// coordinate space (the split view's `convert(_:to: nil)`), so a host view can
/// re-convert it into its own bounds. `isVertical` mirrors the producing split
/// view's orientation: a vertical split view lays its arranged subviews out
/// side-by-side, so its divider is a vertical bar that resizes left/right.
public struct DividerRegion: Equatable, Sendable {
    /// The divider rectangle expressed in window coordinates.
    public let rectInWindow: NSRect

    /// Whether the producing split view is vertical (side-by-side arrangement,
    /// left/right resize) as opposed to horizontal (stacked, up/down resize).
    public let isVertical: Bool

    /// Creates a divider region.
    /// - Parameters:
    ///   - rectInWindow: The divider rectangle in window coordinates.
    ///   - isVertical: Whether the producing split view is vertical.
    public init(rectInWindow: NSRect, isVertical: Bool) {
        self.rectInWindow = rectInWindow
        self.isVertical = isVertical
    }
}

/// Walks an `NSSplitView` tree and reports every divider as a window-space
/// ``DividerRegion``.
///
/// This is the shared geometry pass behind the browser and terminal window
/// portals' `resetCursorRects` overrides: each host view runs the detector over
/// its window's split hierarchy, then maps the returned regions onto its own
/// host-specific cursor rects. The traversal is pure (it only reads frames and
/// orientation and converts coordinates), so it carries no host-view identity
/// and no cursor/hit-test policy; callers keep that app-side.
public struct SplitDividerRegionDetector {
    /// Creates a detector. The detector holds no state; it is a value type so
    /// callers can construct it inline at each `resetCursorRects` call.
    public init() {}

    /// Collects every split-view divider reachable from `view`, expressed in
    /// window coordinates.
    ///
    /// Hidden subtrees are skipped. For each `NSSplitView`, a divider is emitted
    /// between consecutive arranged subviews when at least one neighbour has a
    /// non-trivial extent along the split axis; degenerate (zero-area) converted
    /// rectangles are dropped. The walk descends into all subviews so nested
    /// split views are included.
    /// - Parameter view: The root view to traverse (typically the window's
    ///   content view or a portal's divider-search root).
    /// - Returns: The divider regions in traversal order.
    public func collectRegions(in view: NSView) -> [DividerRegion] {
        var result: [DividerRegion] = []
        collect(in: view, into: &result)
        return result
    }

    private func collect(in view: NSView, into result: inout [DividerRegion]) {
        guard !view.isHidden else { return }

        if let splitView = view as? NSSplitView {
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(
                    DividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in view.subviews {
            collect(in: subview, into: &result)
        }
    }
}
