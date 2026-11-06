public import AppKit

/// Content that handles presses in its own part of the window's title row: a web page, whose
/// controls AppKit cannot see. The page starts the window drag or the double-click action itself
/// for its row's background (`TitleRowHostView.takesTitleRowPress(from:atWindowPoint:)`).
@MainActor
public protocol TitleRowSelfHandling: NSView {}

/// A view that can fill the main pane with no tab strip above it (a top
/// page: Import history, History, Settings), so that its top row is the
/// window's title bar, like the sidebar header beside it
/// (https://github.com/manaflow-ai/cmux/issues/36897).
///
/// `TitlebarDragPolicy` asks it for points in the window's top row only.
/// Inside a container that answers for its own top row (a pane, under its
/// tab strip) the container decides, as it would without this view. With
/// none, a press moves the window, except on a native control or on
/// ``TitleRowSelfHandling`` content, which keep their press.
open class TitleRowHostView: NSView, TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        if let container = decidingContainer { return container.titlebarPress(atWindowPoint: windowPoint) }
        guard let superview else { return .staysPut }
        var view = hitTest(superview.convert(windowPoint, from: nil))
        while let current = view, current !== self {
            if current is NSControl || current is any TitleRowSelfHandling { return .staysPut }
            view = current.superview
        }
        return .movesWindow
    }

    /// The nearest ancestor that answers for its own top row (a pane), if any.
    private var decidingContainer: (any TitlebarPressDeciding)? {
        var ancestor = superview
        while let current = ancestor {
            if let container = current as? TitlebarPressDeciding { return container }
            ancestor = current.superview
        }
        return nil
    }

    /// Whether a press `content` reports at `windowPoint` on its own row background moves the
    /// window: `content` sits in a title row host with no deciding container above it (a top page,
    /// not a pane tab), and the point is in the window's top row.
    public static func takesTitleRowPress(from content: NSView, atWindowPoint windowPoint: CGPoint) -> Bool {
        guard let window = content.window, TitlebarDragPolicy.topRowContains(windowPoint, in: window) else { return false }
        var ancestor = content.superview
        while let current = ancestor {
            if let host = current as? TitleRowHostView { return host.decidingContainer == nil }
            if current is TitlebarPressDeciding { return false }
            ancestor = current.superview
        }
        return false
    }
}
