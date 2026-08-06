import Testing
import UIKit

@testable import CmuxMobileSupport

@MainActor
@Suite struct MobileKeyboardFrameTrackerTests {
    /// Builds the keyboard notification shape UIKit posts, on a private center
    /// so fixtures never leak into other suites.
    private func post(
        _ name: Notification.Name,
        endFrame: CGRect? = nil,
        to center: NotificationCenter
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let endFrame {
            userInfo[UIResponder.keyboardFrameEndUserInfoKey] = endFrame
        }
        center.post(Notification(name: name, object: nil, userInfo: userInfo))
    }

    @Test func willChangeFrameRecordsOverlapForAnAttachedView() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )

        #expect(abs(tracker.overlap(in: view) - 300) <= 0.5)
    }

    @Test func detachedViewReportsZeroOverlapUntilAttached() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )

        // The transition is recorded even though no view can resolve it yet;
        // that is the whole point of the tracker.
        #expect(tracker.overlap(in: view) == 0)
        #expect(tracker.latestTransition != nil)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(abs(tracker.overlap(in: view) - 300) <= 0.5)
    }

    @Test func offscreenEndFrameReportsZeroOverlap() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 800, width: 400, height: 300),
            to: center
        )

        #expect(tracker.overlap(in: view) == 0)
    }

    @Test func didChangeFrameSupersedesTheWillChangeTransition() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 534, width: 400, height: 266),
            to: center
        )
        post(
            UIResponder.keyboardDidChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )

        // The settled frame wins, so layout catch-ups converge on final geometry.
        #expect(abs(tracker.overlap(in: view) - 300) <= 0.5)
    }

    @Test func didHideClearsTheTrackedTransition() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )
        #expect(tracker.latestTransition != nil)

        post(UIResponder.keyboardDidHideNotification, to: center)
        #expect(tracker.latestTransition == nil)
    }

    @Test func backgroundingClearsTheTrackedTransition() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )
        #expect(tracker.latestTransition != nil)

        post(UIApplication.didEnterBackgroundNotification, to: center)
        #expect(tracker.latestTransition == nil)
    }

    @Test func notificationWithoutAnEndFrameClearsTheTrackedTransition() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)

        post(
            UIResponder.keyboardWillChangeFrameNotification,
            endFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            to: center
        )
        post(UIResponder.keyboardWillChangeFrameNotification, to: center)

        // An unreadable follow-up means the keyboard state is unknown; fail
        // closed so a stale floor cannot keep the dock raised.
        #expect(tracker.latestTransition == nil)
    }
}
