#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShell

/// With Reduce Motion on, the team drawer slid the card and parallaxed the
/// sidebar on every open and close (Teams, the scrim, a released drag). It
/// now settles in place: the end geometry, hit-testing and VoiceOver state
/// land at once and no spatial animation runs. A drag still follows the
/// finger. The end point alone is no proof: an animator writes the final
/// model values at once too, so each check also reads the layers'
/// animations.
@MainActor
@Suite(.serialized) struct DrawerReduceMotionTests {
    @MainActor
    struct Drawer {
        let controller: SidebarContainerViewController
        let model: SidebarModel
        let sidebar: UIViewController
        let content: UIViewController
        let window: UIWindow
        /// The card the content sits in (it slides).
        var card: UIView { content.view.superview! }
        var moving: Bool {
            !(card.layer.animationKeys() ?? []).isEmpty || !(sidebar.view.layer.animationKeys() ?? []).isEmpty
        }
    }

    func drawer(reducesMotion: Bool) -> Drawer {
        let model = SidebarModel()
        let sidebar = UIViewController()
        let content = UIViewController()
        let controller = SidebarContainerViewController(model: model, sidebar: sidebar, content: content)
        controller.reducesMotion = { reducesMotion }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return Drawer(controller: controller, model: model, sidebar: sidebar, content: content, window: window)
    }

    func expectOpen(_ drawer: Drawer) {
        #expect(!drawer.moving, "no slide or parallax runs")
        #expect(drawer.card.transform.tx == drawer.sidebar.view.bounds.width)
        #expect(drawer.sidebar.view.transform.tx == 0)
        #expect(drawer.model.isOpen)
        #expect(drawer.model.progress == 1)
        #expect(!drawer.sidebar.view.isHidden)
        #expect(drawer.content.view.accessibilityElementsHidden, "VoiceOver reads the sidebar, not the card")
        #expect(!drawer.sidebar.view.accessibilityElementsHidden)
    }

    func expectClosed(_ drawer: Drawer) {
        #expect(!drawer.moving, "no slide or parallax runs")
        #expect(drawer.card.transform.tx == 0)
        #expect(!drawer.model.isOpen)
        #expect(drawer.model.progress == 0)
        #expect(drawer.sidebar.view.isHidden, "the closed sidebar leaves the screen at once")
        #expect(drawer.card.layer.cornerRadius == 0)
        #expect(!drawer.content.view.accessibilityElementsHidden)
    }

    @Test func openingAndClosingSettleInPlace() {
        let drawer = drawer(reducesMotion: true)
        defer { drawer.window.isHidden = true }
        drawer.model.open()
        expectOpen(drawer)
        // Dismissed through the scrim (or Escape).
        drawer.model.close()
        expectClosed(drawer)
    }

    @Test func aReleasedDragSettlesInPlaceAndTheDragFollowsTheFinger() {
        let drawer = drawer(reducesMotion: true)
        defer { drawer.window.isHidden = true }
        drawer.model.beginTracking()
        drawer.model.track(translationX: 120)
        #expect(drawer.card.transform.tx == 120, "the card follows the finger")
        drawer.model.endTracking(velocityX: 800)
        expectOpen(drawer)
        drawer.model.beginTracking()
        drawer.model.track(translationX: -60)
        drawer.model.endTracking(velocityX: -800)
        expectClosed(drawer)
    }

    /// UIKit starts an animation from what was last committed: commit the
    /// drawer at rest, as it is for frames before a tap.
    func commit() {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// The oracle sees motion: with Reduce Motion off the drawer still
    /// slides, and only settles when the animation ends.
    @Test func withoutReduceMotionTheDrawerStillSlides() {
        let closed = drawer(reducesMotion: false)
        defer { closed.window.isHidden = true }
        commit()
        closed.model.open()
        #expect(closed.moving, "the card slides open")

        // Closing from an open drawer at rest (opened in place, then
        // committed), not mid-open: a close right after an open in the same
        // turn starts from the uncommitted closed position and adds nothing.
        let open = drawer(reducesMotion: true)
        defer { open.window.isHidden = true }
        open.model.open()
        commit()
        open.controller.reducesMotion = { false }
        open.model.close()
        #expect(open.moving, "the card slides closed")
        #expect(!open.sidebar.view.isHidden, "the sidebar stays until the card has slid closed")
    }
}
#endif
