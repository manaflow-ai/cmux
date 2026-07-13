public import AppKit

/// Resolves the sidebar list's enclosing `NSScrollView` for the SwiftUI layer
/// (``SidebarScrollViewResolver``), which applies the sidebar configuration in
/// ``AppKit/NSScrollView/applySidebarScrollIndicatorConfiguration()`` through
/// `onResolve`.
public final class SidebarScrollViewResolverView: NSView {
    /// Invoked with the resolved enclosing scroll view (or `nil`) after each
    /// deferred resolution hop.
    public var onResolve: ((NSScrollView?) -> Void)?

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollView()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollView()
    }

    /// Resolves the enclosing scroll view after one deferred main-actor hop so
    /// the view hierarchy settles before the configuration is applied.
    ///
    /// `nonisolated` keeps lifecycle callers from requiring a synchronous
    /// main-actor hop. The body only schedules a `@MainActor` task, so the
    /// actual resolution still runs on the main actor.
    public nonisolated func resolveScrollView() {
        // Deferred one main-actor hop so the view hierarchy settles before
        // the SwiftUI hosting scroll view and its representable sibling exist.
        Task { @MainActor [weak self] in
            guard let self else { return }
            onResolve?(self.resolveNearestScrollView())
        }
    }

    /// SwiftUI places a representable used as a scroll view background beside
    /// its `HostingScrollView`, rather than inside it. Walk only as far as the
    /// first shared ancestor containing a scroll view at this resolver's
    /// layout point, which avoids selecting unrelated window scroll views.
    private func resolveNearestScrollView() -> NSScrollView? {
        if let enclosingScrollView {
            return enclosingScrollView
        }

        var ancestor = superview
        while let currentAncestor = ancestor {
            let resolverPoint = convert(
                NSPoint(x: bounds.midX, y: bounds.midY),
                to: currentAncestor
            )
            let candidates = descendantScrollViews(in: currentAncestor).filter { scrollView in
                scrollView.bounds.contains(scrollView.convert(resolverPoint, from: currentAncestor))
            }
            if candidates.count > 1 {
                return nil
            }
            if let candidate = candidates.first {
                return candidate
            }
            ancestor = currentAncestor.superview
        }
        return nil
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { subview in
            let current = (subview as? NSScrollView).map { [$0] } ?? []
            return current + descendantScrollViews(in: subview)
        }
    }
}
