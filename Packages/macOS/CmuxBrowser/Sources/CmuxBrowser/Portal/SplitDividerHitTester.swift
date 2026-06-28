public import AppKit

/// Recursively hit-tests a window-coordinate point against the split-view
/// dividers in a view subtree for the browser window portal.
///
/// The tester is constructed with the portal `hostView`; each `hit(at:in:)`
/// call walks `view`'s subtree front-to-back and reports the first split-view
/// divider under the point, tagging whether that divider descends from the
/// host (hosted web content) or sits in the app's split layout.
public struct SplitDividerHitTester {
    /// The portal host view. A divider hit is classified as hosted content when
    /// the owning split view descends from this view.
    public let hostView: NSView

    /// Create a hit-tester anchored to `hostView`.
    public init(hostView: NSView) {
        self.hostView = hostView
    }

    /// Walk `view`'s subtree (front-to-back) and return the split-view divider
    /// hit by `windowPoint`, or `nil` if no divider is under the point.
    /// `windowPoint` is in window coordinates so it stays valid across the
    /// recursion regardless of each view's own coordinate space.
    @MainActor
    public func hit(at windowPoint: NSPoint, in view: NSView) -> SplitDividerHit? {
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
            if let hit = hit(at: windowPoint, in: subview) {
                return hit
            }
        }

        return nil
    }
}
