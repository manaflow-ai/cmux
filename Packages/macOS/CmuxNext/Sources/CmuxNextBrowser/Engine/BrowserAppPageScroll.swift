public import AppKit

/// The scroll position of a cmux page in a browser tab (`BrowserAppPage`) across a hibernation:
/// read from the page's first scroll view when it goes, put back on the rebuilt page's when it
/// shows. The rebuilt page loads its rows after it shows, so a position its document cannot hold
/// yet waits for the document to grow to it, as Blink applies a history item's scroll offset on
/// the layouts after the load until the document can take it
/// (third_party/blink/renderer/core/loader/frame_loader.cc, `RestoreScrollPositionAndViewState`),
/// and gives up once the person scrolled (`ScrollAnchor` and the history item's
/// `did_restore_from_history` rules). A close ends the wait; a hide puts it off to the next show.
@MainActor
public final class BrowserAppPageScroll {
    /// The position the rebuilt page goes back to; nil once it did, or when there is none.
    public private(set) var pending: BrowserAppPageState.Point?
    private weak var scrollView: NSScrollView?
    /// Where the list was when the wait began: another origin at a growth means someone scrolled it.
    private var startOrigin: NSPoint = .zero
    private var observer: (any NSObjectProtocol)?
    /// Where AppKit posts the document's frame changes (tests pass their own).
    private let center: NotificationCenter

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// The visible origin of the first scroll view in `view`'s tree; nil when it has none.
    public static func origin(in view: NSView) -> BrowserAppPageState.Point? {
        guard let scroll = firstScrollView(in: view) else { return nil }
        let origin = scroll.documentVisibleRect.origin
        return BrowserAppPageState.Point(x: Double(origin.x), y: Double(origin.y))
    }

    /// Keeps `point` for the page's next show (``pageDidShow(_:)``).
    public func restore(_ point: BrowserAppPageState.Point?) {
        cancel()
        pending = point
    }

    /// The page shows in `view`: its first scroll view goes to the kept position now when its
    /// document holds it, else when the document grows to it. A hosted SwiftUI list builds its
    /// scroll view in its first layout, so a page in a window is laid out first.
    public func pageDidShow(_ view: NSView) {
        guard pending != nil, scrollView == nil else { return }
        if Self.firstScrollView(in: view) == nil, view.window != nil { view.layoutSubtreeIfNeeded() }
        guard let scroll = Self.firstScrollView(in: view), let document = scroll.documentView else { return }
        scrollView = scroll
        startOrigin = scroll.contentView.bounds.origin
        if apply() { return }
        // raw-observer-allow: the document view is the hosted list's own (SwiftUI's), so its growth reaches no
        // layout() of ours and no WindowEvents or AppEvents notice; one observer on that view, until it applies, hides or closes.
        observer = center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
            // main-proof: AppKit posts a view's frame change on the main thread; queue nil runs the block there.
            MainActor.assumeIsolated { _ = self?.apply() }
        }
    }

    /// The page hid before it got its position: the next show tries again.
    public func pageDidHide() {
        scrollView = nil
        removeObserver()
    }

    /// Stops waiting (the page closed).
    public func cancel() {
        pending = nil
        scrollView = nil
        removeObserver()
    }

    /// Scrolls to the kept position when the document is large enough; true when it did, or
    /// when there is nothing left to do (the person scrolled, the list went).
    private func apply() -> Bool {
        guard let point = pending, let scroll = scrollView, let document = scroll.documentView,
              scroll.contentView.bounds.origin == startOrigin else {
            cancel()
            return true
        }
        let visible = scroll.contentView.bounds.size
        guard point.x <= Double(max(0, document.frame.width - visible.width)),
              point.y <= Double(max(0, document.frame.height - visible.height)) else { return false }
        scroll.contentView.scroll(to: NSPoint(x: point.x, y: point.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        cancel()
        return true
    }

    private func removeObserver() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    /// The first scroll view in `view`'s tree, breadth first (a page's main list or document).
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        var queue: [NSView] = [view]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let scroll = next as? NSScrollView { return scroll }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }
}
