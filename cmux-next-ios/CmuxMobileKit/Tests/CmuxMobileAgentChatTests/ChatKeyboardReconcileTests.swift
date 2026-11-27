#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
import CmuxMobileSupport
import CmuxMobileDesign

/// A chat controller can outlive its window while the app-wide tracker hears a
/// keyboard hide. The controller's own notification observer then has no hide
/// to consume, so the dock must follow the tracker's drop of a keyboard nothing owns
/// (`MobileKeyboardFrameTracker.dropKeyboardWithoutOwner`).
@MainActor
@Suite(.serialized) struct ChatKeyboardReconcileTests {
    private static func look(background: String, picture: UIImage?) throws -> CmuxMobileChatLook {
        let appearance = CmuxMobileMacAppearance(
            theme: .init(background: background, foreground: "#cdd6f4",
                         palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                                   "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]),
            chat: .init(background: background, foreground: "#cdd6f4", backgroundOpacity: 0.45))
        let palette = try #require(CmuxMobileMacPalette(appearance))
        return CmuxMobileChatLook(chat: try #require(appearance.chat), palette: palette, picture: picture)
    }

    private func ownedController() -> (ChatTranscriptController, UIWindow) {
        let controller = ChatTranscriptController(
            placement: .owned, surface: AgentChatSurface(), store: AgentChatStore(source: SmoothChatTests.Silent()),
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil
        )
        controller.topInset = 44
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (controller, window)
    }

    private func rgba(_ color: UIColor?, _ controller: UIViewController) -> [CGFloat]? {
        guard let color = color?.resolvedColor(with: controller.traitCollection) else { return nil }
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return [r, g, b, a].map { ($0 * 255).rounded() }
    }

    /// The top chrome is installed for an owned chat and frames the header. The ground is behind the
    /// transcript, so the rows scroll under the glass bar (an opaque shelf over them hid that).
    @Test func anOwnedChatGetsTopChromeThatDoesNotCoverTheScroll() throws {
        let (controller, window) = ownedController()
        defer { window.isHidden = true }
        controller.applyChatLook(nil)
        controller.view.layoutIfNeeded()

        let chrome = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "agentChat.topChrome" })
        #expect(chrome.frame.height >= 44, "owned chat top chrome must cover its header: \(chrome.frame)")
        #expect(chrome.backgroundColor == .clear || chrome.backgroundColor == nil, "an opaque shelf hides the scroll under the glass bar")
        controller.topInset = 68
        controller.view.layoutIfNeeded()
        #expect(chrome.frame.height >= 68, "top chrome lost the updated safe-area inset: \(chrome.frame)")
    }

    @Test func theGroundBehindTheTranscriptFollowsTheLook() throws {
        let (controller, window) = ownedController()
        defer { window.isHidden = true }

        controller.applyChatLook(nil)
        #expect(rgba(controller.view.backgroundColor, controller) == rgba(.cmuxMobileBackground, controller), "stock ground")

        let flat = try Self.look(background: "#1e1e2e", picture: nil)
        controller.applyChatLook(flat)
        #expect(rgba(controller.view.backgroundColor, controller) == [0x1e, 0x1e, 0x2e, 255], "a flat look paints its ground")

        let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        controller.applyChatLook(try Self.look(background: "#1e1e2e", picture: picture))
        #expect(rgba(controller.view.backgroundColor, controller)?.last == 0, "a picture look stays clear so the picture shows")

        // And back: the flat ground returns, not a stale clear.
        controller.applyChatLook(flat)
        #expect(rgba(controller.view.backgroundColor, controller) == [0x1e, 0x1e, 0x2e, 255])
    }

    @Test func aDetachedHideReturnsTheChatDockToTheBottom() throws {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        tracker.keyboardOwnerPresent = { false }
        // This test's window has no scene, so UIKit's keyboard layout guide never
        // moves for a posted frame (the iOS 26 simulator kept the dock at rest, CI run
        // 45364817994). The dock then follows the notified frames, the path a stalled
        // guide takes. The override is this controller's own, so no other suite's
        // controller sees it (the shared probe latch stays untouched).
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(
            placement: .owned, surface: surface, store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil,
            keyboardTracker: tracker, assumesStalledLayoutGuide: true
        )
        // The kit's test host has no window scene (connectedScenes is empty there), so the window
        // is made without one when none exists. The posted frame is then built from the view's
        // own space through the screen space notifiedTop converts from, so the keyboard top lands
        // 374 pt up whatever that window's screen mapping is. This test (#46792) never ran green
        // on base: the posted frame left the dock at rest (866), see #53107.
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
        let dock = try #require(controller.view.subviews.compactMap { $0 as? PassthroughView }.first)
        let after = controller.view.keyboardLayoutGuide.layoutFrame
        let views = controller.view.subviews.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: "; ")
        #expect(dock.frame.maxY < controller.view.bounds.maxY - 100,
                "the shown keyboard lifts the stale dock: dock \(dock.frame), guide \(after), shown \(shown), bounds \(controller.view.bounds), window=\(controller.view.window != nil), subviews: \(views)")
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
