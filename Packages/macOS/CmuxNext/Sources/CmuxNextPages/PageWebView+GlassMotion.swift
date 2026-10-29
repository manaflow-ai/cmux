public import AppKit
public import CmuxNextDesign

/// The page's glass follows the pane's springs at their start and landing and its moves when they end, never per frame
/// (`GlassBackdropFeed`).
extension PageWebView: PaneMotionTargeting, PaneMotionSettling, PanePlacementFollowing {
    public func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        glassFeed.layoutWillRest()
        return .top
    }

    public func paneMotionDidSettle() {
        glassFeed.landed()
    }

    public func panePlacementDidSettle() {
        glassFeed.placementSettled()
    }
}

extension PageWebView {
    /// Runs one glass feed push (MQ12 held latest): a frozen page holds the newest for its thaw, and
    /// the feed then sends the whole state, so the held push never misses an earlier change.
    func pushGlass(_ script: String) {
        if !pushes.run(script, whileFrozen: .latest(.glass)) { glassFeed.pushWasHeld() }
    }
}
