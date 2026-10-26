import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextInput
import CmuxNextInputCore
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

    @Test func theReleaseFollowsTheRouteItsPressChose() {
        var presses = MouseSideButtons.Presses()
        // Pressed over a remote desktop in control mode: the release goes to the host too, even
        // if control mode turned off or the pointer left the view before it.
        presses.press(.back, route: .pass, browser: nil)
        #expect(presses.release(.back)?.route == .pass)
        // Pressed over a pane: the release runs Go Back once, then nothing is held.
        presses.press(.forward, route: .history(.forward), browser: nil)
        #expect(presses.release(.forward)?.route == .history(.forward))
        #expect(presses.release(.forward) == nil)
        // A release whose press cmux never saw passes on.
        #expect(presses.release(.back) == nil)
    }

    /// A press or release of AppKit button `number` (3 is Back), with no window.
    private static func side(_ type: CGEventType, button number: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
        cg.setIntegerValueField(.mouseEventButtonNumber, value: number)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The tap's intercept answer for `event`, dispatched as the application object does.
    private static func dispatch(_ event: NSEvent, on tap: InputEventTap) -> InputEventTap.InterceptResult {
        var result = InputEventTap.InterceptResult.pass
        tap.dispatching {
            tap.deliverObserve(event)
            result = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
        return result
    }

    @Test func theButtonsAreOneButtonInterceptOnTheTapAndNoMonitor() {
        let tap = InputEventTap()
        let buttons = MouseSideButtons(input: tap)
        #expect(tap.subscriberCount(.button, stage: .intercept) == 0, "nothing before start")
        buttons.start { _ in }
        buttons.start { _ in }
        #expect(buttons.isStarted)
        #expect(tap.subscriberCount(.button, stage: .intercept) == 1)
        for eventClass in InputEventClass.allCases {
            #expect(tap.subscriberCount(eventClass, stage: .observe) == 0)
            #expect(tap.subscriberCount(eventClass, stage: .afterDispatch) == 0)
        }
        #expect(tap.globalMonitorCount == 0)
        buttons.stop()
        #expect(tap.subscriberCount(.button, stage: .intercept) == 0)
    }

    @Test func aBackPressOverAPaneIsConsumedAndItsReleaseRunsGoBackOnce() throws {
        let tap = InputEventTap()
        let buttons = MouseSideButtons(input: tap, locate: { _ in MouseSideButtons.Target() })
        var history: [MouseSideButtons.Button] = []
        buttons.start { history.append($0) }

        #expect(Self.dispatch(try Self.side(.otherMouseDown, button: 3), on: tap) == .consume)
        #expect(history.isEmpty, "the release navigates, as in Chrome")
        #expect(Self.dispatch(try Self.side(.otherMouseUp, button: 3), on: tap) == .consume)
        #expect(history == [.back])
        // A second release with no press of ours goes on.
        #expect(Self.dispatch(try Self.side(.otherMouseUp, button: 3), on: tap) == .pass)
        #expect(history == [.back])
    }

    @Test func otherButtonsAndPressesWithNoWindowGoOn() throws {
        let tap = InputEventTap()
        let buttons = MouseSideButtons(input: tap)
        var history: [MouseSideButtons.Button] = []
        buttons.start { history.append($0) }
        // The middle button opens links; a left click is never ours.
        #expect(Self.dispatch(try Self.side(.otherMouseDown, button: 2), on: tap) == .pass)
        let left = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(Self.dispatch(left, on: tap) == .pass)
        // A side press over no window of ours passes, and so does its release.
        #expect(Self.dispatch(try Self.side(.otherMouseDown, button: 4), on: tap) == .pass)
        #expect(Self.dispatch(try Self.side(.otherMouseUp, button: 4), on: tap) == .pass)
        #expect(history.isEmpty)
    }

    /// Forwards like `RemoteInputCaptureView` in control mode.
    private final class ForwardingView: NSView, MouseButtonForwarding {
        var forwards = false
        var forwardsMouseButtons: Bool { forwards }
    }
}
