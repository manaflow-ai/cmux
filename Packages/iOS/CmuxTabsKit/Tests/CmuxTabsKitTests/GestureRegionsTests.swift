@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// gesture-matrix cells 14-16: which touches TabsKit keeps from the host's
/// back swipe, and where a pinch may start the tab zoom.
struct GestureRegionsTests {
    private let capsule = CGRect(x: 70, y: 780, width: 250, height: 48)
    private let back = CGRect(x: 16, y: 780, width: 48, height: 48)
    private let tabs = CGRect(x: 326, y: 780, width: 48, height: 48)
    private let card = CGRect(x: 16, y: 100, width: 170, height: 240)

    /// Cell 15: a drag on the live bar is the bar swipe; on the page above it, not.
    @Test func barSwipeOwnsTheCapsuleOnThePage() {
        let onBar = CGPoint(x: 150, y: 800)
        #expect(TabsGestureRegions.ownsSidewaysDrag(at: onBar, phase: .page, barSwipes: true, capsule: capsule) { _ in false })
        #expect(!TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 150, y: 400), phase: .page, barSwipes: true, capsule: capsule) { _ in false })
    }

    /// Collapsed or editing, the bar does not swipe: the back swipe keeps it.
    @Test func noBarSwipeNoClaim() {
        #expect(!TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 150, y: 800), phase: .page, barSwipes: false, capsule: capsule) { _ in false })
    }

    /// Cell 16: a drag on an overview card is its close swipe; between cards, not.
    @Test func cardsOwnTheirSwipeOnTheGrid() {
        let onCard: (CGPoint) -> Bool = { self.card.contains($0) }
        #expect(TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 100, y: 200), phase: .overview, barSwipes: false, capsule: capsule, onCard: onCard))
        #expect(!TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 200, y: 50), phase: .overview, barSwipes: false, capsule: capsule, onCard: onCard))
        // The capsule is not on the grid.
        #expect(!TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 150, y: 800), phase: .overview, barSwipes: true, capsule: capsule, onCard: onCard))
    }

    /// Mid-zoom nothing is claimed.
    @Test func noClaimWhileZooming() {
        for phase: TabZoomState.Phase in [.animating, .interactive] {
            #expect(!TabsGestureRegions.ownsSidewaysDrag(at: CGPoint(x: 150, y: 800), phase: phase, barSwipes: true, capsule: capsule) { _ in true })
        }
    }

    /// Cell 14: a pinch on the toolbar never starts the tab zoom; on the page it may.
    @Test func pinchStartsOnlyOffTheToolbar() {
        let toolbar = [back, capsule, tabs]
        #expect(!TabsGestureRegions.pinchStartsOnContent(CGPoint(x: 150, y: 800), phase: .page, toolbar: toolbar))
        #expect(!TabsGestureRegions.pinchStartsOnContent(CGPoint(x: 30, y: 800), phase: .page, toolbar: toolbar))
        #expect(TabsGestureRegions.pinchStartsOnContent(CGPoint(x: 150, y: 400), phase: .page, toolbar: toolbar))
        // The grid has no toolbar: its own card test decides.
        #expect(TabsGestureRegions.pinchStartsOnContent(CGPoint(x: 150, y: 800), phase: .overview, toolbar: toolbar))
    }
}
