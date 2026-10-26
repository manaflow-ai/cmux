public import CmuxNextSignposts

/// A page that says when its document first shows content: the main frame's first contentful paint (Blink's
/// and WebKit's own "the person can see page content now"), the end of its load when the document paints
/// nothing (an empty body), or the failed load or crashed page whose error page or sad tab shows instead. A new
/// tab's `create.tab` interval ends there (p09-observability task 030).
@MainActor
public protocol BrowserFirstContentFrameReporting: AnyObject {
    /// Whether a document is on its way: false for a blank page that loads nothing (its themed background is all it
    /// shows, from the commit that shows it).
    var loadsDocument: Bool { get }

    /// Runs `body` once: with true at the first content frame (at once when it came already), with false when
    /// the page closes first.
    func whenFirstContentFrame(_ body: @escaping @MainActor (_ shown: Bool) -> Void)
}

extension BrowserFirstContentFrameReporting {
    /// This page's first content frame as a new tab's `create.tab` end; `content` is its view in the pane. A page
    /// that loads nothing, or showed content already, shows at the commit that shows it (``CreateTabTimings``).
    public func createTabFirstFrame(content: AnyObject) -> CreateTabTimings.FirstFrame {
        guard loadsDocument else { return .atCommit(content) }
        return .init(content: content) { [weak self] done in
            guard let self else {
                done(.closed)
                return nil
            }
            whenFirstContentFrame { done($0 ? .shown : .closed) }
            return nil
        }
    }
}

/// The waiters of one page's first content frame (``BrowserFirstContentFrameReporting``): each runs exactly once,
/// at the first ``contentShown()`` or at ``closed()``, whichever comes first.
@MainActor
public final class BrowserFirstContentFrame {
    private var waiters: [@MainActor (Bool) -> Void] = []
    /// The page showed content.
    public private(set) var hasShownContent = false
    private var isClosed = false

    public init() {}

    /// Runs `body` at the first content frame, or now when the page showed content or closed already.
    public func add(_ body: @escaping @MainActor (Bool) -> Void) {
        if hasShownContent { return body(true) }
        if isClosed { return body(false) }
        waiters.append(body)
    }

    /// The page showed content (a first contentful paint, a load that ended with nothing to paint, or a failed
    /// load or crashed page whose error page or sad tab shows): every waiter runs with true. Only the first call
    /// does anything.
    public func contentShown() {
        guard !hasShownContent, !isClosed else { return }
        hasShownContent = true
        run(true)
    }

    /// The page closed: the waiters still waiting run with false.
    public func closed() {
        guard !isClosed else { return }
        isClosed = true
        run(false)
    }

    private func run(_ shown: Bool) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(shown) }
    }
}
