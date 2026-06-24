public import AppKit

/// Pure NSView-tree / NSRect predicates that detect a WebKit Web Inspector by its
/// on-screen layout shape.
///
/// cmux cannot ask WebKit whether the inspector is docked, side-docked, or
/// detached, so it infers the layout from the live view tree: walking descendants,
/// matching inspector chrome by ``Foundation/NSObject/cmuxIsWebInspectorObject``,
/// and measuring frame adjacency/overlap. The same predicate set was triplicated
/// across the browser panel, its portal, and its panel view; this detector is the
/// one owner. It holds no state; construct one and call it.
@MainActor
public struct WebInspectorLayoutDetector {
    public init() {}

    /// Every descendant view of `root` in pre-order (root excluded), gathered by an
    /// explicit stack so deep view trees never blow the call stack.
    public func visibleDescendants(in root: NSView) -> [NSView] {
        var descendants: [NSView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            descendants.append(view)
            stack.append(contentsOf: view.subviews.reversed())
        }
        return descendants
    }

    /// Whether `view` is (or hosts) WebKit Web Inspector chrome, matched by class
    /// name through ``Foundation/NSObject/cmuxIsWebInspectorObject``.
    public func isInspectorView(_ view: NSView) -> Bool {
        view.cmuxIsWebInspectorObject
    }

    /// Whether `view` is a plausible side-docked inspector leaf: shown, opaque, and
    /// larger than a 1×1 placeholder in both dimensions.
    public func isVisibleSideDockInspectorCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    /// Whether `view` is a plausible sibling sitting beside a side-docked inspector:
    /// shown, opaque, and larger than a 1×1 placeholder in both dimensions.
    public func isVisibleSideDockSiblingCandidate(_ view: NSView) -> Bool {
        !view.isHidden &&
            view.alphaValue > 0 &&
            view.frame.width > 1 &&
            view.frame.height > 1
    }

    /// The height of the vertical intersection of two frames, clamped to zero when
    /// they do not overlap.
    public func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    /// Whether the subtree rooted at `root` contains any Web Inspector chrome.
    public func windowContainsInspectorViews(_ root: NSView) -> Bool {
        if root.cmuxIsWebInspectorObject {
            return true
        }
        for subview in root.subviews where windowContainsInspectorViews(subview) {
            return true
        }
        return false
    }

    /// Whether `window` is a detached Web Inspector window: titled `Web Inspector`
    /// and hosting inspector chrome in its content view tree.
    public func isDetachedInspectorWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("Web Inspector") else { return false }
        guard let contentView = window.contentView else { return false }
        return windowContainsInspectorViews(contentView)
    }

    /// Whether the subtree rooted at `container` shows a side-docked inspector: any
    /// visible inspector leaf that sits horizontally adjacent to a visible sibling
    /// with meaningful vertical overlap, walking up to `container`. Pass the
    /// web view's superview as `container`; a nil container means no layout to
    /// inspect.
    public func hasSideDockedLayout(in container: NSView?) -> Bool {
        guard let container else { return false }
        return visibleDescendants(in: container)
            .filter { isVisibleSideDockInspectorCandidate($0) && isInspectorView($0) }
            .contains { inspectorCandidate in
                hasSideDockedInspectorSibling(startingAt: inspectorCandidate, root: container)
            }
    }

    /// Whether any ancestor container of `inspectorLeaf` (up to but excluding `root`)
    /// holds a visible sibling beside the inspector: horizontally adjacent within a
    /// 1pt slop and overlapping vertically by more than 8pt.
    private func hasSideDockedInspectorSibling(startingAt inspectorLeaf: NSView, root: NSView) -> Bool {
        var current: NSView? = inspectorLeaf

        while let inspectorView = current, inspectorView !== root {
            guard let containerView = inspectorView.superview else { break }
            let hasSideDockedSibling = containerView.subviews.contains { candidate in
                guard isVisibleSideDockSiblingCandidate(candidate) else { return false }
                guard candidate !== inspectorView else { return false }
                let horizontallyAdjacent =
                    candidate.frame.maxX <= inspectorView.frame.minX + 1 ||
                    candidate.frame.minX >= inspectorView.frame.maxX - 1
                guard horizontallyAdjacent else { return false }
                return verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8
            }
            if hasSideDockedSibling {
                return true
            }

            current = containerView
        }

        return false
    }

    /// The number of Web Inspector chrome views anywhere in the subtree rooted at
    /// `root`, counted by an explicit stack so deep trees never overflow. Used by the
    /// app-side debug geometry summary.
    public func inspectorSubviewCount(in root: NSView) -> Int {
        var stack: [NSView] = [root]
        var count = 0
        while let current = stack.popLast() {
            for subview in current.subviews {
                if subview.cmuxIsWebInspectorObject {
                    count += 1
                }
                stack.append(subview)
            }
        }
        return count
    }
}
