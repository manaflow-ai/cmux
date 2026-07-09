public import AppKit

extension NSView {
    /// Walks this view's subtree (front-to-back) and returns the orientation of
    /// the split-view divider hit by `windowPoint`, or `nil` if no divider is
    /// under the point. The point is in window coordinates so it stays valid
    /// across the recursion regardless of each view's own coordinate space.
    public func splitDividerCursorKind(atWindowPoint windowPoint: NSPoint) -> SplitDividerCursorKind? {
        guard !isHidden else { return nil }

        if let splitView = self as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit) {
                // Keep divider interactions reliable even when portal-hosted terminal frames
                // temporarily overlap divider edges during rapid layout churn.
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
                    let expandedDividerRect = dividerRect.insetBy(dx: -expansion, dy: -expansion)
                    if expandedDividerRect.contains(pointInSplit) {
                        return splitView.isVertical ? .vertical : .horizontal
                    }
                }
            }
        }

        for subview in subviews.reversed() {
            if let kind = subview.splitDividerCursorKind(atWindowPoint: windowPoint) {
                return kind
            }
        }

        return nil
    }

    /// Walks this view's subtree and appends every split-view divider's hit
    /// region (in window coordinates) to `result`. Callers map each region into
    /// their own space to install resize cursor rects.
    public func collectSplitDividerRegions(into result: inout [SplitDividerRegion]) {
        guard !isHidden else { return }

        if let splitView = self as? NSSplitView {
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
                    SplitDividerRegion(
                        rectInWindow: dividerRectInWindow,
                        isVertical: splitView.isVertical
                    )
                )
            }
        }

        for subview in subviews {
            subview.collectSplitDividerRegions(into: &result)
        }
    }
}
