public import AppKit

/// A view that can fill the main pane with no tab strip above it (a top
/// page: Import history, History, Settings), so that its top row is the
/// window's title bar, like the sidebar header beside it
/// (https://github.com/manaflow-ai/cmux/issues/36897).
///
/// `TitlebarDragPolicy` asks it for points in the window's top row only.
/// Inside a container that answers for its own top row (a pane, under its
/// tab strip) the container decides, as it would without this view. With
/// none, a press moves the window, except on a native control inside this
/// view, which keeps its press. A web page's content is no control: the
/// row moves the window over it.
open class TitleRowHostView: NSView, TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        var ancestor = superview
        while let current = ancestor {
            if let container = current as? TitlebarPressDeciding { return container.titlebarPress(atWindowPoint: windowPoint) }
            ancestor = current.superview
        }
        guard let superview else { return .staysPut }
        var view = hitTest(superview.convert(windowPoint, from: nil))
        while let current = view, current !== self {
            if current is NSControl { return .staysPut }
            view = current.superview
        }
        return .movesWindow
    }
}
