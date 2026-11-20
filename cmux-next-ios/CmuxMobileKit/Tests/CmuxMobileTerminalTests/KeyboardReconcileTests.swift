#if os(iOS)
import CmuxMobileSupport
import Testing
import UIKit

/// Leo, 2026-11-17: "the freaking built in keyboard accounting is there when
/// I'm loading back in even when there's no keyboard!" The dock rode the last
/// keyboard frame UIKit posted; back in the app with nothing focused, no hide
/// was posted, so the composer stack sat a keyboard's height above the bottom
/// edge over empty space.
@MainActor
@Suite(.serialized) struct KeyboardReconcileTests {
    private struct Rig {
        let center = NotificationCenter()
        let tracker: MobileKeyboardFrameTracker
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let dock: MobileKeyboardDock
        let view: UIView

        init(focused: @escaping @MainActor () -> Bool) {
            tracker = MobileKeyboardFrameTracker(notificationCenter: center, hasKeyInputFocus: focused)
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            view = controller.view
            dock = MobileKeyboardDock(view: view, usesBottomSafeArea: false, keyboard: tracker)
            view.layoutIfNeeded()
        }

        func showKeyboard() {
            let shown = CGRect(x: 0, y: 874 - 336, width: 402, height: 336)
            center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: shown])
            view.layoutIfNeeded()
        }

        /// What the tracker's owner does as the app comes back (RootView's
        /// scene phase, the terminal page's `appActiveChanged`).
        func becomeActive() {
            tracker.reconcileWithFocus()
            view.layoutIfNeeded()
        }
    }

    @Test func backInTheAppWithNothingFocusedTheDockRestsAtTheBottom() {
        let rig = Rig(focused: { false })
        rig.showKeyboard()
        #expect(rig.tracker.isShown)
        #expect(abs(rig.dock.guide.layoutFrame.minY - (874 - 336)) < 0.5, "the dock rides the shown keyboard")

        var heard: [MobileKeyboardFrameTracker.Change] = []
        rig.tracker.subscribe(rig.view) { _, change in heard.append(change) }
        rig.becomeActive()
        #expect(!rig.tracker.isShown)
        #expect(abs(rig.dock.guide.layoutFrame.minY - 874) < 0.5, "no keyboard: nothing reserved for one")
        #expect(heard.count == 1)
        if case .reconciledHidden = heard.first {} else { Issue.record("subscribers hear the reconcile") }
        rig.window.isHidden = true
    }

    @Test func aFocusedFieldKeepsTheKeyboardItsRecordHolds() {
        let rig = Rig(focused: { true })
        rig.showKeyboard()
        rig.becomeActive()
        #expect(rig.tracker.isShown)
        #expect(!rig.tracker.reconcileWithFocus())
        #expect(abs(rig.dock.guide.layoutFrame.minY - (874 - 336)) < 0.5)
        rig.window.isHidden = true
    }

    @Test func aHiddenKeyboardIsLeftAlone() {
        let rig = Rig(focused: { false })
        #expect(!rig.tracker.reconcileWithFocus(), "no frame recorded yet")
        rig.becomeActive()
        #expect(abs(rig.dock.guide.layoutFrame.minY - 874) < 0.5)
        rig.window.isHidden = true
    }
}
#endif
