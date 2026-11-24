#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
import CmuxMobileSupport

/// A chat controller can outlive its window while the app-wide tracker hears a
/// keyboard hide. The controller's own notification observer then has no hide
/// to consume, so the dock must follow the tracker's drop of a keyboard nothing owns
/// (`MobileKeyboardFrameTracker.dropKeyboardWithoutOwner`).
@MainActor
@Suite(.serialized) struct ChatKeyboardReconcileTests {
    @Test func aDetachedHideReturnsTheChatDockToTheBottom() throws {
        #if DEBUG
        let previousStall = ChatTranscriptController.layoutGuideStallsForTesting
        defer { ChatTranscriptController.layoutGuideStallsForTesting = previousStall }
        #endif
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        tracker.keyboardOwnerPresent = { false }
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(
            placement: .owned, surface: surface, store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil,
            keyboardTracker: tracker
        )
        // Package tests can run without a window scene.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let bounds = controller.view.bounds
        let inView = CGRect(x: 0, y: bounds.maxY - 374, width: bounds.width, height: 374)
        let shown = controller.view.convert(inView, to: window.screen.coordinateSpace)
        // Preconditions for the notified fallback, with their values: the guide rests full width
        // at the bottom (no real keyboard), and the posted frame reads back where it was built.
        let guide = controller.view.keyboardLayoutGuide.layoutFrame
        #expect(guide.width >= bounds.width - 1 && guide.minY > inView.minY + 40,
                "guide at rest: \(guide) in \(bounds), scene=\(scene != nil)")
        let back = controller.view.convert(shown, from: window.screen.coordinateSpace)
        #expect(abs(back.minY - inView.minY) < 1 && abs(back.width - inView.width) < 1,
                "posted frame reads back: \(back) from \(shown), built \(inView)")
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
        let docks = controller.view.subviews.compactMap { $0 as? PassthroughView }
        let dock = try #require(docks.first)
        var shownMessage = "the shown keyboard lifts the stale dock"
        #if DEBUG
        let pins = controller.keyboardPinsForTesting
        let frames = docks.map { "\($0.accessibilityIdentifier ?? "nil")=\($0.frame)" }
        let diagnostic = """
        KEYBOARDRECONCILE windowAttached=\(controller.view.window === window) bounds=\(bounds) \
        screenFrame=\(shown) converted=\(back) guideBefore=\(guide) guideAfter=\(controller.view.keyboardLayoutGuide.layoutFrame) \
        docks=\(frames) notifiedKeyboardTop=\(String(describing: pins.notifiedTop)) \
        layoutGuideStallsBefore=\(previousStall) layoutGuideStalls=\(ChatTranscriptController.layoutGuideStallsForTesting) \
        keyboardPin=\(String(describing: pins.keyboard)) fallbackPin=\(String(describing: pins.fallback))
        """
        print(diagnostic)
        shownMessage += " — " + diagnostic
        #endif
        #expect(dock.frame.maxY < controller.view.bounds.maxY - 100, "\(shownMessage)")
        #expect(tracker.isShown)
        // The controller is detached when the tracker learns the hide. Its
        // own keyboard observer cannot consume a notification it never got.
        window.rootViewController = nil
        window.isHidden = true
        #expect(controller.view.window == nil)
        // Reattaching alone (no explicit drop): the page's appearance asks the
        // tracker to forget the keyboard nothing owns.
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let restingBottom = controller.view.safeAreaLayoutGuide.layoutFrame.maxY - ChatTranscriptController.dockGap
        #expect(!tracker.isShown, "reappearing dropped the keyboard nothing owns")
        #expect(abs(dock.frame.maxY - restingBottom) < 1,
                "the reconciled hide returns the dock to the resting bottom")
    }
}
#endif
