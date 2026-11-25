#if os(iOS)
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The chat dock rides the keyboard's slide; its model frame is at the slide's
/// end from the first frame. A tap on the field where it is drawn mid-slide
/// must reach the field, never the control that sits there at the end
/// (`PassthroughView.hitTest`).
@MainActor
@Suite(.serialized) struct ChatDockDrawnHitTests {
    /// A dock 200 tall: the field in 100..<150, a button under it in 150..<200.
    private func makeDock() -> (UIWindow, PassthroughView, UIView, UIButton) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let dock = PassthroughView(frame: CGRect(x: 0, y: 300, width: 400, height: 200))
        dock.interactiveHeight = 100
        let field = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 50))
        let button = UIButton(frame: CGRect(x: 0, y: 150, width: 400, height: 50))
        dock.addSubview(field)
        dock.addSubview(button)
        root.view.addSubview(dock)
        return (window, dock, field, button)
    }

    @Test func aTapOnTheDrawnFieldMidSlideReachesTheField() throws {
        let (window, dock, field, button) = makeDock()
        defer { window.isHidden = true }
        // The slide up 50 pt, slow and linear: drawn at about its start for the test.
        UIView.animate(withDuration: 30, delay: 0, options: [.curveLinear]) {
            dock.frame.origin.y = 250
        }
        CATransaction.flush()
        let drawn = try #require(dock.layer.presentation())
        #expect(drawn.frame.minY > 295, "still drawn near its start")
        // The field's middle as drawn: y 300 + 125.
        let point = CGPoint(x: 200, y: drawn.frame.minY + 125)
        let hit = window.hitTest(point, with: nil)
        #expect(hit === field, "hit \(String(describing: hit))")
        #expect(hit !== button, "a wrong-target activation")
        dock.layer.removeAllAnimations()
    }

    @Test func atRestTheHitTestIsTheModelOne() {
        let (window, dock, field, button) = makeDock()
        defer { window.isHidden = true }
        #expect(dock.drawnShift == nil)
        #expect(window.hitTest(CGPoint(x: 200, y: 425), with: nil) === field)
        #expect(window.hitTest(CGPoint(x: 200, y: 475), with: nil) === button)
        // Above the interactive band: through to what is behind.
        #expect(window.hitTest(CGPoint(x: 200, y: 350), with: nil) !== dock)
    }
}
#endif
