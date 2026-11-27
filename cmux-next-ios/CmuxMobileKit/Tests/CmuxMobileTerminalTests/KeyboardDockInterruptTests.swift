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

    /// User report 2026-11-05: the keyboard key pressed again while the
    /// keyboard moves jumped the composer. The notifications below are the
    /// ones UIKit posted on an iOS 26.5 simulator (KeyboardToggleInterruptUITests'
    /// trace): an interrupted transition's did-change comes about 5 ms
    /// BEFORE the new transition's will-change and already carries the new
    /// end frame. The dock took that frame and the host's next layout pass
    /// (outside any animation) moved the stack there in one frame. A show
    /// reversed 0.05 s in is posted as a 0-high hide with no animation, which
    /// the dock applied in one frame too.
    @Test func interruptedKeyboardTransitionsMoveTheDockOnlyInsideAnAnimation() throws {
        let center = NotificationCenter()
        // Notifications are timed by this clock, not the simulator's speed.
        var clock: CFTimeInterval = 100
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center, now: { clock })
        let controller = UIViewController()
        // The simulator's own screen: a keyboard wider than it reads as an iPad's.
        let screen = UIScreen.main.bounds
        let window = UIWindow(frame: screen)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = controller.view!
        let dock = MobileKeyboardDock(view: view, usesBottomSafeArea: false, keyboard: tracker)
        let stack = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
            stack.bottomAnchor.constraint(equalTo: dock.guide.topAnchor),
        ])
        view.layoutIfNeeded()
        let bottom = screen.maxY, width = screen.width
        let shown = CGRect(x: 0, y: bottom - 308, width: width, height: 308)
        let hidden = CGRect(x: 0, y: bottom, width: width, height: 308)
        let gone = CGRect(x: 0, y: bottom, width: width, height: 0)
        // A long animation keeps each transition running while the test posts the next.
        func post(_ name: Notification.Name, _ frame: CGRect, duration: Double = 2) {
            center.post(name: name, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: frame,
                UIResponder.keyboardAnimationDurationUserInfoKey: duration,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
        }
        func will(_ frame: CGRect, duration: Double = 2) {
            if duration > 0 {
                // motion: allow test stand-in for the system keyboard's animation.
                UIView.animate(withDuration: duration) { post(UIResponder.keyboardWillChangeFrameNotification, frame, duration: duration) }
            } else {
                post(UIResponder.keyboardWillChangeFrameNotification, frame, duration: 0)
            }
        }
        /// The host's layout pass (TerminalViewController.viewDidLayoutSubviews).
        func hostLayout() {
            dock.refresh()
            UIView.performWithoutAnimation { view.layoutIfNeeded() }
        }
        func settle() {
            stack.layer.removeAllAnimations()
            for sub in view.subviews { sub.layer.removeAllAnimations() }
        }

        // Shown and settled.
        will(shown, duration: 0)
        post(UIResponder.keyboardDidChangeFrameNotification, shown, duration: 0)
        hostLayout()
        #expect(dock.guide.layoutFrame.minY == shown.minY)

        // Hide, then show 0.1 s in: the hide's did comes first, with the show's frame.
        will(hidden)
        settle()
        post(UIResponder.keyboardDidChangeFrameNotification, shown)
        hostLayout()
        #expect(dock.guide.layoutFrame.minY == hidden.minY, "the did notice does not move the dock ahead of the show's animation")
        will(shown)
        #expect(dock.guide.layoutFrame.minY == shown.minY)
        #expect(!(stack.layer.animationKeys() ?? []).isEmpty, "the show moves the stack inside its animation")
        settle()

        // Show, then hide 0.05 s in: a 0-high did, then a hide with no animation.
        post(UIResponder.keyboardDidChangeFrameNotification, gone)
        hostLayout()
        #expect(dock.guide.layoutFrame.minY == shown.minY, "the did notice does not drop the dock")
        will(gone, duration: 0)
        #expect(dock.guide.layoutFrame.minY == bottom)
        #expect(!(stack.layer.animationKeys() ?? []).isEmpty, "an unanimated reversal still carries the stack down from where it is")
        settle()

        // A did with another frame after its will's animation (UIKit retargeted) still counts.
        let taller = CGRect(x: 0, y: bottom - 380, width: width, height: 380)
        will(shown)
        settle()
        clock += 2.5
        post(UIResponder.keyboardDidChangeFrameNotification, taller)
        hostLayout()
        #expect(dock.guide.layoutFrame.minY == taller.minY)
        withExtendedLifetime(dock) {}
        window.isHidden = true
    }
}
#endif
