public import AppKit
import CmuxNextWakeups

/// A woken tab's last frame over its recreated page until the page paints (`BrowserWakeStandIn`).
/// The web view stays visible to WebKit under the picture, so the page renders and paints; the
/// picture goes on the main frame's first contentful paint (`WebKitFirstPaintHandler`), at the cap,
/// and on every exit where no paint comes: the load ends with nothing painted, fails, is stopped,
/// the web content process ends, or the tab closes.
extension WebKitTab: BrowserWakeStandIn {
    @discardableResult
    public func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool {
        guard !isClosed else { return false }
        removeStandIn()
        // Pixels already decoded cover the page from the swap's first frame.
        let view = decoded ? BrowserPictureView(decoded: picture) : BrowserPictureView(picture: { picture })
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .above, relativeTo: webView)
        standIn = view
        let timer = DemandTimer(owner: "WebKitTab.standIn", clock: clock)
        // Justified delay: the cap of a stand-in, not a poll; the paint or any removal cancels it.
        timer.schedule(after: cap) { @MainActor [weak self, weak view] in
            guard let self, let view, self.standIn === view else { return }
            self.removeStandIn()
        }
        standInCap = timer
        return true
    }

    /// The main frame painted content.
    func pageDidPaint() {
        removeStandIn()
    }

    func removeStandIn() {
        standInCap?.cancel()
        standInCap = nil
        standIn?.removeFromSuperview()
        standIn = nil
    }
}
