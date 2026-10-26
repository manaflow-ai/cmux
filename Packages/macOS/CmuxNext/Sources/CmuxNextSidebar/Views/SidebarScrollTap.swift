public import AppKit

/// The app's input tap as the sidebar sees it (`InputEventTap`, p04-input-011): a window-scoped
/// observe subscription to scroll events, called from `sendEvent` before AppKit dispatches them.
/// The tap calls `predicate` once per scroll event of `window`, then `handler` when it accepts.
public protocol SidebarScrollTap: AnyObject {
    /// Observes the scroll events of `window` that `predicate` accepts until the returned
    /// token is released.
    func observeScrolls(in window: NSWindow,
                        where predicate: @escaping @MainActor (NSEvent) -> Bool,
                        handler: @escaping @MainActor (NSEvent) -> Void) -> AnyObject
}

extension SidebarView {
    /// The app's input tap: the list and the spaces bar page from it. Set once by the
    /// composition root; nil leaves both on their own `scrollWheel`.
    public var scrollTap: (any SidebarScrollTap)? {
        get { scrollView.scrollTap }
        set {
            scrollView.scrollTap = newValue
            profileBar.scrollTap = newValue
        }
    }
}
