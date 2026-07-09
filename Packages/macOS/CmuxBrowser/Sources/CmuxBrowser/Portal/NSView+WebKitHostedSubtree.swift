public import AppKit
public import WebKit

extension NSView {
    /// The direct child of this view (treated as the transfer container) whose
    /// subtree contains `descendant`, or `nil` when `descendant` is not a
    /// descendant of this view. Climbs from `descendant` toward this container,
    /// remembering the last view before the container, so callers can reparent
    /// the whole transfer branch (e.g. WebKit's host wrapper around a hosted
    /// `WKWebView`) rather than the leaf web view.
    public func directWebKitTransferChild(containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== self {
            directChild = view
            current = view.superview
        }
        guard current === self else { return nil }
        return directChild
    }

    /// Whether this view's subtree contains any WebKit Web Inspector view,
    /// detected by the package's inspector predicate
    /// (`NSObject.isCmuxWebInspectorObject`). Iterative depth-first walk over the
    /// subview tree, including this view itself.
    public var containsCmuxWebInspectorView: Bool {
        var stack: [NSView] = [self]
        while let current = stack.popLast() {
            if current.isCmuxWebInspectorObject {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    /// The WebKit companion subviews of this host view (the source superview) that
    /// should move with `primaryWebView` during a portal reparent. WebKit injects
    /// sibling `WK*` views (and an inspector frontend) next to a hosted page when
    /// the Web Inspector is docked; moving those with the primary web view keeps
    /// inspector UI state from being orphaned in the old host.
    ///
    /// The primary transfer branch is `directWebKitTransferChild(containing:)`
    /// (falling back to the web view itself); when that branch contains an
    /// inspector view the bare `primaryWebView` is transferred instead so the
    /// inspector window's WebKit observers are not dragged into the portal.
    /// Remaining direct subviews are included when their class name is `WK`-prefixed
    /// and neither the subview's class name nor its subtree is an inspector. Results
    /// are de-duplicated and never include this view itself.
    public func relatedWebKitTransferSubviews(primaryWebView: WKWebView) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== self else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        // The Web Inspector frontend is owned by WebKit's inspector window/controller.
        // Moving it into the portal can leave WebKit window observers pointing at a
        // stale host during user-initiated inspector-window close.
        let primaryTransferView = directWebKitTransferChild(containing: primaryWebView) ?? primaryWebView
        if primaryTransferView.containsCmuxWebInspectorView {
            append(primaryWebView)
        } else {
            append(primaryTransferView)
        }

        for view in subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            if className.isCmuxWebInspectorClassName || view.containsCmuxWebInspectorView {
                continue
            }
            guard className.contains("WK") else { continue }
            append(view)
        }

        return relatedSubviews
    }

    /// The hosted `WKWebView`s reachable from this container view, excluding any
    /// Web Inspector frontend web view (`NSObject.isCmuxWebInspectorObject`).
    /// `primaryWebView` is included first when it is this view, a direct subview,
    /// or a descendant; the rest are gathered by a depth-first subtree walk. An
    /// inspector web view is skipped along with its subtree. Results are
    /// de-duplicated.
    public func hostedWebKitSubviews(primaryWebView: WKWebView) -> [WKWebView] {
        var result: [WKWebView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ webView: WKWebView?) {
            guard let webView else { return }
            guard !webView.isCmuxWebInspectorObject else { return }
            let id = ObjectIdentifier(webView)
            guard seen.insert(id).inserted else { return }
            result.append(webView)
        }

        if primaryWebView === self ||
            primaryWebView.superview === self ||
            primaryWebView.isDescendant(of: self) {
            append(primaryWebView)
        }
        appendHostedWebKitSubviews(to: &result, seen: &seen)
        return result
    }

    /// Append every hosted `WKWebView` in this view's subtree to `result`,
    /// de-duplicating via `seen`. An inspector frontend web view is skipped
    /// together with its subtree (the early return mirrors the legacy behavior of
    /// not descending into an inspector web view).
    private func appendHostedWebKitSubviews(
        to result: inout [WKWebView],
        seen: inout Set<ObjectIdentifier>
    ) {
        if let webView = self as? WKWebView {
            guard !webView.isCmuxWebInspectorObject else { return }
            let id = ObjectIdentifier(webView)
            if seen.insert(id).inserted {
                result.append(webView)
            }
        }
        for subview in subviews {
            subview.appendHostedWebKitSubviews(to: &result, seen: &seen)
        }
    }
}
