public import AppKit
public import WebKit

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

    /// Whether the subtree rooted at `root` contains any Web Inspector chrome,
    /// matching `root` itself or any descendant. Used to decide whether a WebKit
    /// transfer subtree is the inspector frontend that must stay with WebKit rather
    /// than being moved into the portal.
    public func containsInspectorView(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current.cmuxIsWebInspectorObject {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    /// Whether `frame` pokes outside `bounds` on any edge by more than `epsilon`.
    /// Used to decide whether a docked-inspector layout has pushed the page frame
    /// off its container and needs repair.
    public func frameExtendsOutsideBounds(
        _ frame: NSRect,
        bounds: NSRect,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        frame.minX < bounds.minX - epsilon ||
            frame.minY < bounds.minY - epsilon ||
            frame.maxX > bounds.maxX + epsilon ||
            frame.maxY > bounds.maxY + epsilon
    }

    /// Whether the subtree rooted at `root` (root excluded) holds a visible
    /// inspector leaf: shown, opaque, and larger than a 1×1 placeholder in both
    /// dimensions. Walks an explicit stack so deep trees never overflow.
    public func hasVisibleInspectorDescendant(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current !== root {
                if current.cmuxIsWebInspectorObject,
                   !current.isHidden,
                   current.alphaValue > 0,
                   current.frame.width > 1,
                   current.frame.height > 1 {
                    return true
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    /// The frame of a bottom-docked Web Inspector inside `containerView`, inferred
    /// from layout: a sibling of `primaryWebView` that hosts visible inspector
    /// chrome, overlaps the page horizontally by more than 70%, sits flush with the
    /// container bottom, and ends at or below the page top. Returns the tallest such
    /// candidate, or `nil` when no bottom dock is present.
    public func inferredBottomDockedInspectorFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 1
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds

        let candidates = containerView.subviews.compactMap { candidate -> NSRect? in
            guard candidate !== primaryWebView else { return nil }
            guard hasVisibleInspectorDescendant(in: candidate) else { return nil }

            let frame = candidate.frame
            guard frame.width > 1, frame.height > 1 else { return nil }
            let overlapWidth = min(pageFrame.maxX, frame.maxX) - max(pageFrame.minX, frame.minX)
            guard overlapWidth > min(pageFrame.width, frame.width) * 0.7 else { return nil }
            guard frame.minY <= containerBounds.minY + epsilon else { return nil }
            guard frame.maxY <= pageFrame.minY + epsilon else { return nil }
            return frame
        }

        return candidates.max(by: { $0.height < $1.height })
    }

    /// The corrected page frame for `primaryWebView` when a bottom-docked inspector
    /// has pushed it outside `containerView`: the full container width seated above
    /// the inspector's top edge. Returns `nil` when the page is within bounds or no
    /// bottom dock is inferred.
    public func repairedBottomDockedPageFrame(
        in containerView: NSView,
        primaryWebView: WKWebView,
        epsilon: CGFloat = 0.5
    ) -> NSRect? {
        let pageFrame = primaryWebView.frame
        let containerBounds = containerView.bounds
        guard frameExtendsOutsideBounds(pageFrame, bounds: containerBounds, epsilon: epsilon),
              let inspectorFrame = inferredBottomDockedInspectorFrame(
                  in: containerView,
                  primaryWebView: primaryWebView
              ) else {
            return nil
        }

        return NSRect(
            x: containerBounds.minX,
            y: inspectorFrame.maxY,
            width: containerBounds.width,
            height: max(0, containerBounds.maxY - inspectorFrame.maxY)
        )
    }
}
