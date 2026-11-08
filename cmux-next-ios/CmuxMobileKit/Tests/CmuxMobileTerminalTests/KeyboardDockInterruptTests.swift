#if os(iOS)
import CmuxMobileSupport
import Testing
import UIKit

/// User report 2026-10-30: tapping the key row's keyboard key and then the
/// terminal in quick succession did not interrupt the keyboard's animation;
/// the second tap waited for the first animation to finish. The bottom stack
/// rides the keyboard through `MobileKeyboardDock`, whose animation inside the
/// keyboard's own did not allow user interaction, so UIKit dropped every touch
/// on the moving stack (and the views laid out with it) until it settled.
@MainActor
@Suite(.serialized) struct KeyboardDockInterruptTests {
    @Test func stackRidingTheKeyboardStillTakesTouchesMidAnimation() throws {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = controller.view!
        let dock = MobileKeyboardDock(view: view, usesBottomSafeArea: false, keyboard: tracker)
        let key = UIButton(type: .system)
        key.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(key)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            key.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            key.heightAnchor.constraint(equalToConstant: 44),
            key.bottomAnchor.constraint(equalTo: dock.guide.topAnchor),
        ])
        view.layoutIfNeeded()

        // The keyboard shows: UIKit posts its notification inside the
        // keyboard's own animation, which the dock's layout pass inherits.
        let shown = CGRect(x: 0, y: 874 - 336, width: 402, height: 336)
        // motion: allow test stand-in for the system keyboard's animation.
        UIView.animate(withDuration: 2) {
            center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: shown])
        }
        #expect(!(key.layer.animationKeys() ?? []).isEmpty, "the key rides the keyboard's animation")

        // Mid-animation, a tap on the key (where it is going, and where its
        // model layer already is) reaches it: the animation is interruptible.
        let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
        let hit = window.hitTest(view.convert(point, to: window), with: nil)
        #expect(hit === key)
        withExtendedLifetime(dock) {}
        window.isHidden = true
    }
}
#endif
