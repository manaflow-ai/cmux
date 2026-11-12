import CmuxNextWakeups
import Foundation

/// Pages the person waits for: a shown tab whose new browser was asked to show something, from its attach
/// (`CEFTab.attach`) until its document may take keys (`CEFTab.documentArrived`: loaded and painted) or it closes.
/// The warmup makes the next spare window and spare page only once none is arriving (`CEFEngine.pagesArriving`,
/// `ChromiumWarmup`): building a Chromium window holds the main thread, and a spare page starts a renderer, and
/// either one made in a link's load held that page's first paint for seconds under load (Leo 2026-11-05: "it takes
/// EGREGIOUSLY long for me to open up a link/the pane on the right opens"). Chrome starts its spare renderer once
/// the foreground navigation is done, never during it. A page counts for `limit` at most, so one that never paints
/// never holds the warmup back for good.
@MainActor final class CEFArrivingPages {
    /// How long a page counts as arriving at most.
    let limit: Duration
    /// The arriving pages, each with the deadline that ends it.
    private var pages: [BrowserTabID: DemandTimer] = [:]
    /// The last arriving page arrived, closed or ran out of time.
    var onSettled: (@MainActor () -> Void)?

    init(limit: Duration = .seconds(3)) { self.limit = limit }

    var isEmpty: Bool { pages.isEmpty }

    func began(_ id: BrowserTabID) {
        guard pages[id] == nil else { return }
        let deadline = DemandTimer(owner: "CEFArrivingPages.limit")
        pages[id] = deadline
        deadline.schedule(after: limit) { @MainActor [weak self] in self?.ended(id) }
    }

    func ended(_ id: BrowserTabID) {
        guard let deadline = pages.removeValue(forKey: id) else { return }
        deadline.cancel()
        if pages.isEmpty { onSettled?() }
    }
}
