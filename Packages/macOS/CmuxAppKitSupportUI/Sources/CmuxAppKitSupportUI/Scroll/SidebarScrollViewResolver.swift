public import AppKit
public import SwiftUI

/// An invisible `NSViewRepresentable` that resolves the sidebar list's
/// enclosing `NSScrollView` for the SwiftUI layer and reports it back through
/// `onResolve`, so callers can apply overlay-scroller configuration
/// (``AppKit/NSScrollView/applySidebarOverlayScrollerConfiguration()``).
public struct SidebarScrollViewResolver: NSViewRepresentable {
    /// Invoked with the resolved enclosing scroll view (or `nil` when none is
    /// reachable yet) on every resolution pass.
    public let onResolve: (NSScrollView?) -> Void

    /// Creates a resolver that reports the enclosing scroll view via `onResolve`.
    public init(onResolve: @escaping (NSScrollView?) -> Void) {
        self.onResolve = onResolve
    }

    public func makeNSView(context: Context) -> SidebarScrollViewResolverView {
        let view = SidebarScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    public func updateNSView(_ nsView: SidebarScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }
}
