public import AppKit

/// Which of a window's Messages pages (the docked Home, a conversation tab, the Chief panel) an
/// app-wide action means: the one holding the keyboard (its view or an ancestor of it) first,
/// else the first visible one, front to back. `pick` answers for a view, or nil to look on.
@MainActor
public struct HomeShownView {
    public init() {}
    public static func find<T>(in window: NSWindow?, _ pick: (NSView) -> T?) -> T? {
        guard let window else { return nil }
        var responder = window.firstResponder as? NSView
        while let view = responder {
            if let found = pick(view) { return found }
            responder = view.superview
        }
        var stack = [window.contentView].compactMap { $0 }
        while let view = stack.popLast() {
            if !view.isHiddenOrHasHiddenAncestor, let found = pick(view) { return found }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return nil
    }
}
