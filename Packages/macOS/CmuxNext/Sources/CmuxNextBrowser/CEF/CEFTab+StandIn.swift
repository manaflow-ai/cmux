public import CoreGraphics
import AppKit
import CmuxNextWakeups

/// A tab's last frame over its new Chromium page until the page paints (`BrowserWakeStandIn`): a hibernated tab
/// that wakes, and a restored tab first shown after a relaunch (its picture from the run before,
/// `BrowserPageFrames`). The picture is a view over the page area in the tab's container, above the pane's
/// Chromium host view, so the page lays out and paints under it. It goes at the document's first contentful
/// paint (`documentDidFirstPaint`, a paint before the commit, or the page's own answer), at an error page, at the
/// cap, and when the tab closes.
extension CEFTab: BrowserWakeStandIn {
    @discardableResult
    public func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool {
        guard !isClosed else { return false }
        removeStandIn()
        let view = decoded ? BrowserPictureView(decoded: picture) : BrowserPictureView(picture: { picture })
        // The container places it on the page area (`CEFTabContentView.layoutContent`), as it places the page.
        view.frame = container.bounds
        container.addSubview(view, positioned: .above, relativeTo: nil)
        standIn = view
        let timer = DemandTimer(owner: "CEFTab.standIn", clock: clock)
        // Justified delay: the cap of a stand-in, not a poll; the paint or any removal cancels it.
        timer.schedule(after: cap) { @MainActor [weak self, weak view] in
            guard let self, let view, self.standIn === view else { return }
            self.removeStandIn()
        }
        standInCap = timer
        host.lifecycleTrace.record(id, "stand-in shown")
        return true
    }

    /// Whether the tab's last frame covers its page now.
    public var showsStandIn: Bool { standIn != nil }

    func removeStandIn() {
        guard let standIn else { return }
        standInCap?.cancel()
        standInCap = nil
        standIn.removeFromSuperview()
        self.standIn = nil
    }
}
