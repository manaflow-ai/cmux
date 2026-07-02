import AppKit

/// Sidebar tree views (e.g. the Notes outline) that own file-bearing drags
/// over their region. The window file-drop overlay owns ALL file drags
/// window-wide by design; for these regions it forwards the dragging events
/// to the registered view — the same way it forwards to WKWebViews — so the
/// tree's own validate/accept machinery (drop indicators, row targeting,
/// in-tree moves) keeps working. The overlay never accepted drops over the
/// sidebar anyway: there is no pane underneath it.
///
/// Registration (NSView `viewDidMoveToWindow`) and hit-testing (dragging
/// callbacks) both happen on the main thread, so MainActor isolation guards
/// the weak view table instead of a lock.
@MainActor
enum SidebarFileDropDeferralRegistry {
    private static let registeredViews = NSHashTable<NSView>.weakObjects()

    static func register(_ view: NSView) {
        registeredViews.add(view)
    }

    static func unregister(_ view: NSView) {
        registeredViews.remove(view)
    }

    private static func isVisibleInHierarchy(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alphaValue > 0 else { return false }
            current = candidate.superview
        }
        return true
    }

    static func containsWindowPoint(_ windowPoint: CGPoint, in window: NSWindow) -> Bool {
        view(atWindowPoint: windowPoint, in: window) != nil
    }

    static func view(atWindowPoint windowPoint: CGPoint, in window: NSWindow) -> NSView? {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in registeredViews.allObjects {
            guard view.window === window, isVisibleInHierarchy(view) else { continue }
            guard let hitBounds = visibleBounds(for: view) else { continue }
            let frameInWindow = view.convert(hitBounds, to: nil).insetBy(dx: -epsilon, dy: -epsilon)
            if frameInWindow.contains(windowPoint) {
                return view
            }
        }
        return nil
    }

    private static func visibleBounds(for view: NSView) -> NSRect? {
        var bounds = view.bounds
        if let clipView = view.enclosingScrollView?.contentView,
           clipView.documentView === view {
            bounds = bounds.intersection(clipView.documentVisibleRect)
        }
        return bounds.isEmpty || bounds.isNull ? nil : bounds
    }
}
