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
}
