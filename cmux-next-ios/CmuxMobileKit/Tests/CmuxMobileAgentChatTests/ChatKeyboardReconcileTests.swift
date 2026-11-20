#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
import CmuxMobileSupport

/// A chat controller can outlive its window while the app-wide tracker hears a
/// keyboard hide. The controller's own notification observer then has no hide
/// to consume, so the dock must follow the tracker's reconciled frame.
@MainActor
@Suite(.serialized) struct ChatKeyboardReconcileTests {
    @Test func aDetachedHideReturnsTheChatDockToTheBottom() throws {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center, hasKeyInputFocus: { false })
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(
            placement: .owned, surface: surface, store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil,
            keyboardTracker: tracker
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let shown = CGRect(x: 0, y: 500, width: 402, height: 374)
        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: shown),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            UIResponder.keyboardAnimationCurveUserInfoKey: UIView.AnimationCurve.easeInOut.rawValue,
        ]
        // The tracker hears the app-wide record, while the controller hears
        // only its own view observer. This models the hide occurring while
        // the controller is detached from the window.
        center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: userInfo)
        UIView.performWithoutAnimation {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: userInfo)
        }
        controller.view.layoutIfNeeded()
        let dock = try #require(controller.view.subviews.compactMap { $0 as? PassthroughView }.first)
        #expect(dock.frame.maxY < controller.view.bounds.maxY - 100, "the shown keyboard lifts the stale dock")
        #expect(tracker.isShown)

        #expect(tracker.reconcileWithFocus(), "the tracker emits the detached hide")
        controller.view.layoutIfNeeded()
        #expect(abs(dock.frame.maxY - (controller.view.bounds.maxY - ChatTranscriptController.dockGap)) < 1,
                "the reconciled hide returns the dock to the resting bottom")
    }
}
#endif
