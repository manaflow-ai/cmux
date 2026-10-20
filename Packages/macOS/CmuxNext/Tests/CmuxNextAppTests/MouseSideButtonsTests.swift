import AppKit
@testable import CmuxNextApp
import Testing

/// Mouse buttons 4 and 5 are Back and Forward (plans/cmux-next/history.md 4.2): a browser tab's
/// history over the tab, Go Back and Go Forward elsewhere, nothing over a remote desktop that
/// sends every button to its host.
@MainActor @Suite struct MouseSideButtonsTests {
    @Test func appKitButtonsThreeAndFourAreBackAndForward() {
        #expect(MouseSideButtons.Button(buttonNumber: 3) == .back)
        #expect(MouseSideButtons.Button(buttonNumber: 4) == .forward)
        #expect(MouseSideButtons.Button(buttonNumber: 2) == nil) // middle click opens links
        #expect(MouseSideButtons.Button(buttonNumber: 5) == nil)
    }

    @Test func aBrowserTabWalksItsHistoryAndAnyOtherPaneWalksGoBack() {
        typealias Route = MouseSideButtons.Route
        #expect(Route.of(.back, enabled: true, overForwardingView: false, overBrowser: true) == .page(.back))
        #expect(Route.of(.forward, enabled: true, overForwardingView: false, overBrowser: false) == .history(.forward))
        #expect(Route.of(.back, enabled: true, overForwardingView: true, overBrowser: false) == .pass)
        #expect(Route.of(.back, enabled: false, overForwardingView: false, overBrowser: true) == .pass)
        #expect(Route.of(nil, enabled: true, overForwardingView: false, overBrowser: true) == .pass)
    }

    @Test func aRemoteDesktopInControlModeKeepsTheButtons() {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let remote = ForwardingView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let inner = NSView(frame: remote.bounds)
        remote.addSubview(inner)
        content.addSubview(remote)
        let overRemote = window.convertPoint(toScreen: CGPoint(x: 100, y: 150))
        let beside = window.convertPoint(toScreen: CGPoint(x: 300, y: 150))

        remote.forwards = true
        #expect(MouseSideButtons.Target(window: window, screenPoint: overRemote).forwardsButtons)
        #expect(!MouseSideButtons.Target(window: window, screenPoint: beside).forwardsButtons)
        remote.forwards = false
        #expect(!MouseSideButtons.Target(window: window, screenPoint: overRemote).forwardsButtons)
        #expect(MouseSideButtons.Target(window: window, screenPoint: beside).browser == nil)
    }

    /// Answers `-cmuxForwardsMouseButtons` like `RemoteInputCaptureView`.
    private final class ForwardingView: NSView {
        var forwards = false
        @objc var cmuxForwardsMouseButtons: Bool { forwards }
    }
}
