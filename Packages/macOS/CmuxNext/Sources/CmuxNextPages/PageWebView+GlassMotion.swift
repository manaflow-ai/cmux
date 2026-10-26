public import AppKit
public import CmuxNextDesign

/// The page's glass follows the pane's springs at their start and landing and its moves when they end, never per frame
/// (`GlassBackdropFeed`, chrome-parity p03-rendering-037).
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
