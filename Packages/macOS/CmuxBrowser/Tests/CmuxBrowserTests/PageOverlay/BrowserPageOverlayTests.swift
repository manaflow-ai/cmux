import AppKit
import Testing

@testable import CmuxBrowser

@Suite struct BrowserPageOcclusionPlanTests {
    @Test func holesAreClippedToThePage() {
        let plan = BrowserPageOcclusionPlan(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            overlayRects: [
                CGRect(x: 280, y: 250, width: 200, height: 40), // find bar, partly past the right edge
                CGRect(x: -100, y: -50, width: 50, height: 50), // outside the page
            ]
        )
        #expect(plan.holes == [CGRect(x: 280, y: 250, width: 120, height: 40)])
    }

    @Test func nestedHolesAreDroppedButEqualOnesKeepOne() {
        let plan = BrowserPageOcclusionPlan(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            overlayRects: [
                CGRect(x: 0, y: 0, width: 400, height: 300), // crash page
                CGRect(x: 10, y: 10, width: 100, height: 20), // a bar over it
                CGRect(x: 0, y: 0, width: 400, height: 300), // the same page twice
            ]
        )
        #expect(plan.holes == [CGRect(x: 0, y: 0, width: 400, height: 300)])
    }

    @Test func roundedCardsGetANotchedHoleThatLeavesTheCornersToThePage() {
        let card = CGRect(x: 100, y: 50, width: 200, height: 80)
        let plan = BrowserPageOcclusionPlan(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            overlays: [.init(rect: card, cornerRadius: 10)]
        )
        let holes = plan.holes
        #expect(holes.count > 3)
        // No two rects overlap: the fork masks even-odd, so an overlap would show the page again.
        for (i, a) in holes.enumerated() {
            for b in holes[(i + 1)...] {
                #expect(a.intersection(b).isEmpty || a.intersection(b).isNull)
            }
        }
        // Their union is the card minus what lies outside its rounded corners
        // (about (4 - pi) r^2 in all, within the one-point steps).
        let area = holes.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let cutAway = card.width * card.height - area
        #expect(cutAway > 0)
        #expect(abs(cutAway - (4 - .pi) * 100) < 40)
        let union = holes.dropFirst().reduce(holes[0]) { $0.union($1) }
        #expect(union == card)
        for corner in [CGPoint(x: 101, y: 51), CGPoint(x: 299, y: 51), CGPoint(x: 101, y: 129), CGPoint(x: 299, y: 129)] {
            #expect(!holes.contains { $0.contains(corner) })
        }
        #expect(holes.contains { $0.contains(CGPoint(x: 200, y: 51)) })
        // Just inside the arc near a corner the card shows.
        #expect(holes.contains { $0.contains(CGPoint(x: 104, y: 54)) })
    }

    @Test func squareBarsAndTinyCardsKeepOneRect() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(BrowserPageOcclusionPlan(contentBounds: bounds, overlays: [.init(rect: CGRect(x: 0, y: 0, width: 400, height: 30))]).holes
            == [CGRect(x: 0, y: 0, width: 400, height: 30)])
        #expect(BrowserPageOcclusionPlan(contentBounds: bounds, overlays: [.init(rect: CGRect(x: 0, y: 0, width: 15, height: 15), cornerRadius: 10)]).holes
            == [CGRect(x: 0, y: 0, width: 15, height: 15)])
    }

    @Test func aBarOverAFullPageCardMakesNoHoleOfItsOwn() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let holes = BrowserPageOcclusionPlan(contentBounds: bounds, overlays: [
            .init(rect: bounds),
            .init(rect: CGRect(x: 20, y: 20, width: 100, height: 40), cornerRadius: 8),
        ]).holes
        #expect(holes == [bounds])
    }

    @Test func overlappingCardsCutOneHoleWithNoOverlap() {
        // A find bar over a permission strip in a short pane.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let strip = CGRect(x: 0, y: 150, width: 400, height: 40)
        let find = CGRect(x: 200, y: 130, width: 180, height: 40)
        let holes = BrowserPageOcclusionPlan(contentBounds: bounds, overlays: [.init(rect: strip), .init(rect: find)]).holes
        for (i, a) in holes.enumerated() {
            for b in holes[(i + 1)...] {
                let overlap = a.intersection(b)
                #expect(overlap.isNull || overlap.isEmpty, "holes overlap: \(a) \(b)")
            }
        }
        let area = holes.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let shared = strip.intersection(find)
        #expect(area == strip.width * strip.height + find.width * find.height - shared.width * shared.height)
        // Every point of either card is in exactly one hole.
        for point in [CGPoint(x: 10, y: 160), CGPoint(x: 300, y: 140), CGPoint(x: 300, y: 160)] {
            #expect(holes.filter { $0.contains(point) }.count == 1)
        }
    }

    @Test func disjointUnionJoinsMatchingBands() {
        let single = BrowserPageOcclusionPlan.disjointUnion([
            CGRect(x: 0, y: 0, width: 100, height: 10),
            CGRect(x: 0, y: 10, width: 100, height: 10),
        ])
        #expect(single == [CGRect(x: 0, y: 0, width: 100, height: 20)])
        let apart = BrowserPageOcclusionPlan.disjointUnion([
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 50, y: 0, width: 10, height: 10),
        ])
        #expect(apart.count == 2)
    }

    @Test func fractionalFramesRoundOutward() {
        let plan = BrowserPageOcclusionPlan(
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            overlayRects: [CGRect(x: 10.5, y: 10.25, width: 20, height: 20)]
        )
        #expect(plan.holes == [CGRect(x: 10, y: 10, width: 21, height: 21)])
    }
}

@MainActor
private final class FakeOcclusionTarget: BrowserPageOcclusionHosting {
    var pageOcclusionRects: [CGRect] = []
}

/// Runs everything already queued on the main queue (the coordinator
/// publishes its floating placement there), with no timer.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// A flipped page view, like many AppKit host views.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
@Suite(.serialized) struct BrowserPageOverlayCoordinatorTests {
    private func makeWindow() -> (NSWindow, NSView, NSView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let page = NSView(frame: CGRect(x: 100, y: 0, width: 500, height: 360))
        root.addSubview(page)
        return (window, root, page)
    }

    @Test func occludingOverlayMakesAHoleOnlyForAChildWindowPage() async {
        let (window, root, page) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 400, y: 300, width: 180, height: 40))
        root.addSubview(anchor)
        let coordinator = BrowserPageOverlayCoordinator()
        let target = FakeOcclusionTarget()

        coordinator.registerOccluding(anchor, id: "find")
        coordinator.attach(contentView: page, target: nil)
        await drainMainQueue()
        #expect(!coordinator.hostsFloatingOverlaysInPanels)
        #expect(target.pageOcclusionRects.isEmpty)

        coordinator.attach(contentView: page, target: target)
        // Published on the next main-queue turn (attach runs inside SwiftUI updates).
        #expect(!coordinator.hostsFloatingOverlaysInPanels)
        await drainMainQueue()
        #expect(coordinator.hostsFloatingOverlaysInPanels)
        #expect(target.pageOcclusionRects == [CGRect(x: 300, y: 300, width: 180, height: 40)])

        anchor.isHidden = true
        coordinator.update()
        #expect(target.pageOcclusionRects.isEmpty)

        anchor.isHidden = false
        coordinator.update()
        #expect(target.pageOcclusionRects.count == 1)

        coordinator.unregisterOccluding(id: "find")
        #expect(target.pageOcclusionRects.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func holesFollowThePaneAndClearWhenThePageLeaves() async {
        let (window, root, page) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 100, y: 0, width: 500, height: 360))
        root.addSubview(anchor)
        let coordinator = BrowserPageOverlayCoordinator()
        let target = FakeOcclusionTarget()
        coordinator.attach(contentView: page, target: target)
        coordinator.registerOccluding(anchor, id: "crash")
        #expect(target.pageOcclusionRects == [CGRect(x: 0, y: 0, width: 500, height: 360)])

        // The pane moves (a split resizes it): the hole follows the page.
        page.frame = CGRect(x: 200, y: 0, width: 400, height: 360)
        anchor.frame = page.frame
        coordinator.update()
        #expect(target.pageOcclusionRects == [CGRect(x: 0, y: 0, width: 400, height: 360)])

        // Workspace switch: the page is hidden; no hole is left behind.
        page.isHidden = true
        coordinator.update()
        #expect(target.pageOcclusionRects.isEmpty)

        page.isHidden = false
        coordinator.detach()
        await drainMainQueue()
        #expect(target.pageOcclusionRects.isEmpty)
        #expect(!coordinator.hostsFloatingOverlaysInPanels)
        withExtendedLifetime(window) {}
    }

    @Test func holesFollowAFlippedPageView() {
        let (window, root, _) = makeWindow()
        let page = FlippedView(frame: CGRect(x: 100, y: 0, width: 500, height: 360))
        root.addSubview(page)
        // 40 pt bar at the top of the page (window y 320...360).
        let anchor = NSView(frame: CGRect(x: 100, y: 320, width: 500, height: 40))
        root.addSubview(anchor)
        let coordinator = BrowserPageOverlayCoordinator()
        let target = FakeOcclusionTarget()
        coordinator.attach(contentView: page, target: target)
        coordinator.registerOccluding(anchor, id: "bar")
        #expect(target.pageOcclusionRects == [CGRect(x: 0, y: 0, width: 500, height: 40)])
        withExtendedLifetime(window) {}
    }

    @Test func registeredCornerRadiusNotchesTheHole() {
        let (window, root, page) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 200, y: 100, width: 200, height: 100))
        root.addSubview(anchor)
        let coordinator = BrowserPageOverlayCoordinator()
        let target = FakeOcclusionTarget()
        coordinator.attach(contentView: page, target: target)
        coordinator.registerOccluding(anchor, id: "card", cornerRadius: 10)
        #expect(target.pageOcclusionRects.count > 1)
        coordinator.registerOccluding(anchor, id: "card")
        #expect(target.pageOcclusionRects == [CGRect(x: 100, y: 100, width: 200, height: 100)])
        withExtendedLifetime(window) {}
    }

    @Test func swappingTheTargetClearsTheOldOne() {
        let (window, root, page) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 150, y: 10, width: 50, height: 50))
        root.addSubview(anchor)
        let coordinator = BrowserPageOverlayCoordinator()
        let first = FakeOcclusionTarget()
        let second = FakeOcclusionTarget()
        coordinator.registerOccluding(anchor, id: "bar")
        coordinator.attach(contentView: page, target: first)
        #expect(!first.pageOcclusionRects.isEmpty)
        coordinator.attach(contentView: page, target: second)
        #expect(first.pageOcclusionRects.isEmpty)
        #expect(second.pageOcclusionRects == [CGRect(x: 50, y: 10, width: 50, height: 50)])
        withExtendedLifetime(window) {}
    }

    @Test func additionalOcclusionRectKeepsNativeDragTargetAbovePage() {
        let (window, root, page) = makeWindow()
        let coordinator = BrowserPageOverlayCoordinator()
        let target = FakeOcclusionTarget()
        coordinator.attach(contentView: page, target: target)
        coordinator.additionalOcclusionRects = [CGRect(x: 0, y: 0, width: 500, height: 360)]

        #expect(target.pageOcclusionRects == [CGRect(x: 0, y: 0, width: 500, height: 360)])
        coordinator.additionalOcclusionRects = []
        #expect(target.pageOcclusionRects.isEmpty)
        withExtendedLifetime((window, root)) {}
    }
}
