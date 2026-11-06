public import AppKit

/// Content that handles presses in its own part of the window's title row: a web page, whose
/// controls AppKit cannot see. The page starts the window drag or the double-click action itself
/// for its row's background (`TitleRowHostView.takesTitleRowPress(from:atWindowPoint:)`).
@MainActor
public protocol TitleRowSelfHandling: NSView {}

/// A view that can fill the main pane with no tab strip above it (a top
/// page: Import history, Stats, History), so that its top row is the
/// window's title bar, like the sidebar header beside it
/// (https://github.com/manaflow-ai/cmux/issues/36897).
///
/// `TitlebarDragPolicy` asks it for points in the window's top row only.
/// Inside a container that answers for its own top row (a pane, under its
/// tab strip) the container decides, as it would without this view. With
/// none, native content answers as it would with no host (the window's own
/// rule: a press moves the window unless it lands on a control or a view that
/// refuses window moves, and only in the band), and ``TitleRowSelfHandling``
/// content (a web page) keeps its press: it reports the presses on its own row
/// background itself.
open class TitleRowHostView: NSView, TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        if let container = decidingContainer { return container.titlebarPress(atWindowPoint: windowPoint) }
        guard let window, let superview, let content = window.contentView,
              TitlebarDragPolicy.bandRect(in: window).contains(windowPoint) else { return .staysPut }
        var view = hitTest(superview.convert(windowPoint, from: nil))
        var background = view != nil
        while let current = view {
            if current is any TitleRowSelfHandling { return .staysPut }
            if current is NSControl || !current.mouseDownCanMoveWindow { background = false }
            if current === content { break }
            view = current.superview
        }
        return background && view === content ? .movesWindow : .staysPut
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
