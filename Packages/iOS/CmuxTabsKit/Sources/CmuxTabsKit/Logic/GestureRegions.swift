import CoreGraphics

/// Which gesture a touch on the tabs screen belongs to, where TabsKit and
/// the host's recognizers could both take it (cmux-next-ios
/// design/gesture-matrix.md, cells 14-16). Points are in the tabs screen's
/// coordinate space.
enum TabsGestureRegions {
    /// Whether a sideways drag starting at `point` is TabsKit's own: the bar
    /// swipe between tabs on the toolbar capsule (live only while the bar is
    /// expanded and not editing), or the close swipe of an overview card. A
    /// host's back swipe must not start there.
    static func ownsSidewaysDrag(at point: CGPoint, phase: TabZoomState.Phase, barSwipes: Bool, capsule: CGRect,
                                 onCard: (CGPoint) -> Bool) -> Bool {
        switch phase {
        case .page: barSwipes && capsule.contains(point)
        case .overview: onCard(point)
        case .animating, .interactive: false
        }
    }

    /// Whether a pinch whose fingers' midpoint started at `centroid` may drive
    /// the tab zoom: on the page, only off the toolbar's controls (a pinch
    /// there is no page's); elsewhere the caller's own test (a grid card,
    /// a running zoom) decides.
    static func pinchStartsOnContent(_ centroid: CGPoint, phase: TabZoomState.Phase, toolbar: [CGRect]) -> Bool {
        phase != .page || !toolbar.contains { $0.contains(centroid) }
    }
}
