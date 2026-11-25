public import AppKit

extension NSView {
    /// Takes this view out of its parent, then every subview out of it, in this turn, while every view in the
    /// subtree lives. An owner calls it when it lets go of a view that may hold an embedded page (a page tab's or
    /// a top page's view): the page must never leave its hierarchy inside this view's `-[NSView dealloc]`. A hidden
    /// page that loses its hidden ancestor there makes AppKit call the CEF fork's parent tracker, which stored a weak
    /// reference to the deallocating view and aborted the app (SIGABRT "Cannot form weak reference ... deallocation"
    /// in `CmuxParentViewTracker`; cmux21 cmux-2026-10-28-114922.ips, a closed hidden Settings tab).
    public func removeFromSuperviewDetachingSubviews() {
        removeFromSuperview()
        for subview in subviews { subview.removeFromSuperview() }
    }
}
