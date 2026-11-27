public import AppKit
import CmuxNextWakeups

/// Whether a page shows on screen now, the sight half of a web swap (``WebSwapGate/sight(inSight:)``):
/// in a window that is visible and not fully covered (`occlusionState`, which also reads a minimized
/// window, another Space and a hidden app as out of sight), with no hidden view above it and some of
/// it inside its window.
public struct WebSwapSight {
    public init() {}
    public static func inSight(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor else { return false }
        let shown = view.convert(view.bounds, to: nil).intersection(window.contentView?.frame ?? .zero)
        return !shown.isNull && shown.width > 1 && shown.height > 1
    }
}

/// Swaps a background web change (``WebDevOverride/background``) holds back from the pages in sight:
/// each page takes it once it is out of sight (``PageWebView/swapReload()``), or drops it when it
/// drew a new document meanwhile (a reload or navigation loads the newer web anyway). One look every
/// ``WebSwapGate``-style retry while any page waits; none otherwise.
@MainActor
public final class WebSwapDeferred {
    /// How long between looks while a page waits (the safe point's own retry).
    static let retry: Duration = .seconds(2)

    private struct Waiting {
        weak var page: PageWebView?
        /// The document the page showed when its swap was held: a new one ends the wait.
        let painted: TimeInterval?
        let swap: @MainActor (PageWebView) -> Void
    }

    private var waiting: [ObjectIdentifier: Waiting] = [:]
    private let timer = DemandTimer(owner: "web-swap.deferred")

    init() {}
    /// Tests: what counts as in sight (``WebSwapSight/inSight(_:)``).
    var inSight: @MainActor (NSView) -> Bool = { WebSwapSight.inSight($0) }

    /// The pages waiting now.
    public var count: Int { waiting.values.filter { $0.page != nil }.count }

    /// Holds `swap` for `page` until it is out of sight (a later hold of the same page replaces it).
    func hold(_ page: PageWebView, swap: @escaping @MainActor (PageWebView) -> Void) {
        waiting[ObjectIdentifier(page)] = Waiting(page: page, painted: page.paintedUptime, swap: swap)
        schedule()
    }

    /// One look: each waiting page out of sight swaps now; the rest wait for the next look.
    func look() {
        for (key, entry) in waiting {
            guard let page = entry.page, !page.isClosed, page.paintedUptime == entry.painted else {
                waiting[key] = nil
                continue
            }
            guard !inSight(page) else { continue }
            waiting[key] = nil
            entry.swap(page)
        }
        schedule()
    }

    private func schedule() {
        guard !waiting.isEmpty else { return timer.cancel() }
        // wakeup-allow: one look per retry only while a page holds a background swap; none at rest.
        timer.schedule(after: Self.retry) { @MainActor [weak self] in self?.look() }
    }
}
