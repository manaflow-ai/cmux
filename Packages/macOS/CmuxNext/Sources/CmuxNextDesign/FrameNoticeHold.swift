public import AppKit

/// Views whose frame notices someone reads (`NSView.frameDidChangeNotification`), kept by the layout root above
/// them (``FrameNoticeReadersHosting``), so a ``FrameNoticeHold`` never holds them: their notices post on every change.
/// A reader that also reads its ancestors' notices (the Chromium fork's page tracker, a glass lens) gives
/// `onAncestorMove`: while a hold keeps those ancestors quiet, the hold runs it once for each frame in which the
/// reader's place in the window changed and its own frame did not.
@MainActor
public final class FrameNoticeReaders {
    private final class Entry {
        let onAncestorMove: () -> Void
        init(_ onAncestorMove: @escaping () -> Void) { self.onAncestorMove = onAncestorMove }
    }

    private let entries = NSMapTable<NSView, Entry>.weakToStrongObjects()

    public init() {}

    /// `view`'s frame notices are read; `onAncestorMove` stands in for its ancestors' notices while they are held.
    public func add(_ view: NSView, onAncestorMove: @escaping () -> Void) {
        entries.setObject(Entry(onAncestorMove), forKey: view)
    }

    public func remove(_ view: NSView) {
        entries.removeObject(forKey: view)
    }

    public func contains(_ view: NSView) -> Bool { entries.object(forKey: view) != nil }

    /// An ancestor's clip changed without moving its readers.
    public func notifyGeometryChange() {
        for case let view as NSView in entries.keyEnumerator().allObjects {
            entries.object(forKey: view)?.onAncestorMove()
        }
    }

    func onAncestorMove(of view: NSView) -> (() -> Void)? { entries.object(forKey: view)?.onAncestorMove }
}

/// A view that keeps the frame-notice readers below it (cmux-next's layout root).
@MainActor
public protocol FrameNoticeReadersHosting: NSView {
    var frameNoticeReaders: FrameNoticeReaders { get }
}

extension NSView {
    /// The readers of the nearest ``FrameNoticeReadersHosting`` view at or above this one; nil with none.
    public var enclosingFrameNoticeReaders: FrameNoticeReaders? {
        var view: NSView? = self
        while let current = view {
            if let host = current as? any FrameNoticeReadersHosting { return host.frameNoticeReaders }
            view = current.superview
        }
        return nil
    }
}

/// Keeps a subtree's frame notices for the end of a resize drag or a zoom's spring: one notice per moved view when it ends,
/// none on its frames.
///
/// AppKit posts a frame notice for each frame change of a view, and after each post of a view with controls in
/// the titlebar band, or of one of their ancestors (a pane's tab strip, its pane views), it marks the window's
/// drag margins dirty (`-[NSView _postFrameChangeNotification]` -> `-[NSWindow _setNeedsToResetDragMargins:]`,
/// read from AppKit on macOS 27). The commit of that frame then walks the window's views for the titlebar drag shapes and
/// sends them to the window server: about a quarter of a divider drag frame's commit (RESIZE P0 17, cmux21).
/// cmux windows move only with `performDrag` (`TitlebarDragPolicy`), so the shapes are the same at the end.
/// A view with `postsFrameChangedNotifications` off posts nothing and dirties nothing; turning it back on posts
/// once when its frame changed in between (AppKit's documented behavior), and that post marks the margins once.
///
/// Never held: scroll views and everything in them (clip and document notices drive their layout), the
/// ``FrameNoticeReaders`` and everything in them, and views that already posted nothing.
@MainActor
public final class FrameNoticeHold {
    private struct Held {
        weak var view: NSView?
    }

    private struct Reader {
        weak var view: NSView?
        var frame: CGRect
        var inWindow: CGRect
    }

    private var held: [Held] = []
    private var readers: [Reader] = []
    /// The readers above the held roots.
    private var registry: FrameNoticeReaders?

    public init() {}

    public var isHolding: Bool { !held.isEmpty || !readers.isEmpty }

    /// Holds the subtrees of `roots`. Holding again first gives back what is held.
    public func hold(_ roots: [NSView]) {
        release()
        registry = roots.lazy.compactMap(\.enclosingFrameNoticeReaders).first
        for root in roots { collect(root) }
    }

    /// Runs the readers' `onAncestorMove` for the readers that moved in the window with their own frame unchanged
    /// (their own frame change posted its notice). Call once per frame, after the frame's layout.
    public func noteFrame() { // perf-hot: 0.05ms drag-frame (one convert per page or lens in the held panes)
        for index in readers.indices {
            guard let view = readers[index].view else { continue }
            let frame = view.frame
            let inWindow = view.window == nil ? .null : view.convert(view.bounds, to: nil)
            guard inWindow != readers[index].inWindow else { continue }
            let ownFrameChanged = frame != readers[index].frame
            readers[index].frame = frame
            readers[index].inWindow = inWindow
            if !ownFrameChanged { registry?.onAncestorMove(of: view)?() }
        }
    }

    /// Gives every held view its notices back: each one whose frame changed posts once now.
    public func release() {
        let views = held.compactMap(\.view)
        held = []
        readers = []
        registry = nil
        for view in views { view.postsFrameChangedNotifications = true }
    }

    private func collect(_ view: NSView) {
        if view is NSScrollView { return }
        if let registry, registry.contains(view) {
            readers.append(Reader(view: view, frame: view.frame,
                                  inWindow: view.window == nil ? .null : view.convert(view.bounds, to: nil)))
            return
        }
        if view.postsFrameChangedNotifications {
            view.postsFrameChangedNotifications = false
            held.append(Held(view: view))
        }
        for subview in view.subviews { collect(subview) }
    }
}
