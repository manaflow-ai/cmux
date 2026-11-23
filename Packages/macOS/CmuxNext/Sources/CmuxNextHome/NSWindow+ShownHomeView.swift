public import AppKit

extension NSWindow {
    /// Which of this window's Home views (the docked Home, a conversation tab, the Chief panel) an
    /// app-wide action means: the one holding the keyboard (its view or an ancestor of it) first, else
    /// the first visible one, front to back. `pick` answers for a view, or nil to look on.
    @MainActor
    public func shownHomeView<T>(_ pick: (NSView) -> T?) -> T? {
        var responder = firstResponder as? NSView
        while let view = responder {
            if let found = pick(view) { return found }
            responder = view.superview
        }
        var stack = [contentView].compactMap { $0 }
        while let view = stack.popLast() {
            if !view.isHiddenOrHasHiddenAncestor, let found = pick(view) { return found }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return nil
    }
}
