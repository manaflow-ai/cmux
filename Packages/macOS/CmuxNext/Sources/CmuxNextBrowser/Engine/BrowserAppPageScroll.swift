public import AppKit
import CmuxNextDesign
import CmuxNextSignposts

/// The scroll position of a cmux page in a browser tab (`BrowserAppPage`) across a hibernation:
/// read from the page's main list when it goes, put back on the rebuilt page's when it shows.
/// Each page names its main list (``listScrollView(in:)``, ``soleScrollView(in:)``, or a view it
/// owns); none is guessed. The rebuilt page loads its rows after it shows, so a position its list
/// cannot hold yet is tried again after each Core Animation commit (the pass that lays new rows
/// out), as Blink applies a history item's scroll offset on each layout after the load until the
/// document can take it, and clamps it once the content is there
/// (third_party/blink/renderer/core/loader/frame_loader.cc, `RestoreScrollPositionAndViewState`).
/// The person's scroll ends the wait (the history item's `did_restore_from_history` rule); a close
/// ends it; a hide puts it off to the next show. A commit comes only when the run loop turns, so an
/// idle page costs nothing while it waits; a cmux page has no load end, so the wait ends after
/// ``commitLimit`` commits (an empty folder or search never grows).
@MainActor
public final class BrowserAppPageScroll {
    /// Runs `body` once, after the next Core Animation commit of the main run loop.
    public typealias AfterCommit = @MainActor (_ body: @escaping @MainActor () -> Void) -> Void

    /// The commits one show waits through at most.
    public static let commitLimit = 240

    /// The position the rebuilt page goes back to; nil once it did, or when there is none.
    public private(set) var pending: BrowserAppPageState.Point?
    /// A show is waiting for the list to hold ``pending``.
    public private(set) var isWaiting = false
    /// The list the wait found: another origin of it at a try means someone scrolled it.
    private weak var scrollView: NSScrollView?
    private var startOrigin: NSPoint = .zero
    /// Bumped by each show, hide and close: a commit callback of an older wait does nothing.
    private var generation: UInt64 = 0
    private let afterCommit: AfterCommit

    /// - Parameter afterCommit: When the next layout reached the screen (default:
    ///   ``afterNextCommit(_:)``; tests fire it by hand).
    public init(afterCommit: @escaping AfterCommit = BrowserAppPageScroll.afterNextCommit) {
        self.afterCommit = afterCommit
    }

    /// Runs `body` after the next Core Animation commit (``CommitBoundary``). A named function, not
    /// a closure in the default argument: a public default argument may only reference public
    /// declarations, and this file imports CmuxNextSignposts internally.
    public static func afterNextCommit(_ body: @escaping @MainActor () -> Void) {
        CommitBoundary().after { _ in body() }
    }

    /// The visible origin of `scroll`; nil without one.
    public static func origin(of scroll: NSScrollView?) -> BrowserAppPageState.Point? {
        guard let scroll else { return nil }
        let origin = scroll.documentVisibleRect.origin
        return BrowserAppPageState.Point(x: Double(origin.x), y: Double(origin.y))
    }

    /// What a hibernation saves of `scroll`: the kept position while it has not gone back yet (a
    /// page discarded again before its rows came keeps it), else where `scroll` is.
    public func position(of scroll: NSScrollView?) -> BrowserAppPageState.Point? {
        pending ?? Self.origin(of: scroll)
    }

    /// Keeps `point` for the page's next show (``pageDidShow(list:hasRows:)``).
    public func restore(_ point: BrowserAppPageState.Point?) {
        cancel()
        pending = point
    }

    /// The page shows. `list` names its main list (nil while the page has not built it) and
    /// `hasRows` says whether the page's model holds its rows yet. The kept position goes there now
    /// when the list holds it, else after a later commit: when the rows are there and laid out but
    /// the list is shorter than the position, it goes to the list's end.
    public func pageDidShow(list: @escaping @MainActor () -> NSScrollView?, hasRows: @escaping @MainActor () -> Bool) {
        guard pending != nil, !isWaiting else { return }
        generation &+= 1
        isWaiting = true
        attempt(generation, commitsLeft: Self.commitLimit, list: list, hasRows: hasRows)
    }

    /// The page hid before it got its position: the next show tries again.
    public func pageDidHide() {
        generation &+= 1
        isWaiting = false
        scrollView = nil
    }

    /// Stops waiting (the page closed, or its position applied).
    public func cancel() {
        pending = nil
        pageDidHide()
    }

    private func attempt(_ wait: UInt64, commitsLeft: Int, list: @escaping @MainActor () -> NSScrollView?,
                         hasRows: @escaping @MainActor () -> Bool) {
        guard wait == generation, isWaiting else { return }
        if apply(list(), clamping: hasRows()) { return }
        guard commitsLeft > 0 else { return cancel() }
        afterCommit { [weak self] in self?.attempt(wait, commitsLeft: commitsLeft - 1, list: list, hasRows: hasRows) }
    }

    /// Scrolls `found` to the kept position when its document holds it (or to its end, `clamping`
    /// once the rows are there); true when it did, or when there is nothing left to do (the person
    /// scrolled). False while the list is not built, not laid out or too short.
    private func apply(_ found: NSScrollView?, clamping: Bool) -> Bool {
        guard let point = pending else { return true }
        guard let scroll = found, let document = scroll.documentView else { return false }
        if scrollView !== scroll {
            scrollView = scroll
            startOrigin = scroll.contentView.bounds.origin
        } else if scroll.contentView.bounds.origin != startOrigin {
            cancel()
            return true
        }
        let visible = scroll.contentView.bounds.size
        let end = (x: Double(max(0, document.frame.width - visible.width)), y: Double(max(0, document.frame.height - visible.height)))
        let holds = point.x <= end.x && point.y <= end.y
        // Rows in the model but none laid out yet: the next commit lays them out.
        guard holds || (clamping && document.frame.height > visible.height) else { return false }
        scroll.contentView.scroll(to: NSPoint(x: min(point.x, end.x), y: min(point.y, end.y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        cancel()
        return true
    }

    // MARK: Naming a page's main list

    /// The scroll view of the page's one SwiftUI `List` (AppKit backs a `List` with an
    /// `NSTableView` in an `NSScrollView`): nil when `view` holds none or more than one.
    public static func listScrollView(in view: NSView) -> NSScrollView? {
        sole(scrollViews(in: view).filter { $0.documentView is NSTableView })
    }

    /// The page's one scroll view: nil when `view` holds none or more than one.
    public static func soleScrollView(in view: NSView) -> NSScrollView? {
        sole(scrollViews(in: view))
    }

    private static func sole(_ views: [NSScrollView]) -> NSScrollView? {
        views.count == 1 ? views.first : nil
    }

    /// The scroll views of `view`'s tree, outermost only (one inside a list's rows is the row's).
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var queue: [NSView] = [view]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let scroll = next as? NSScrollView {
                found.append(scroll)
            } else {
                queue.append(contentsOf: next.subviewsIncludingGated)
            }
        }
        return found
    }
}
