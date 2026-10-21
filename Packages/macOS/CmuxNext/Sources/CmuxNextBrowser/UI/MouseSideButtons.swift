import AppKit
import CmuxNextDesign

/// Mouse buttons 4 and 5 are Back and Forward (plans/cmux-next/history.md 4.2), as in Chrome,
/// Safari, Claude and Codex. Over a browser tab (its page or its toolbar) they walk that tab's
/// history, through the same `BrowserChromeView` command as `browserBack`; anywhere else they run
/// the app's Go Back and Go Forward (`history`: the shown page's own history, then the location
/// trail, 4.2b). A view that forwards every button to something else (`MouseButtonForwarding`, a
/// remote desktop in control mode) keeps them. The press is consumed and the release navigates,
/// as in Chrome; the release follows the route its press chose.
///
/// A Chromium page draws in its own child window, so a press on it arrives in that window; the
/// browser tab is found in the cmux window that holds it (`window.parent`).
public final class MouseSideButtons {
    public nonisolated enum Button: Equatable, Hashable, Sendable {
        case back
        case forward

        /// AppKit numbers the buttons from 0: 3 is the fourth (Back), 4 the fifth (Forward).
        init?(buttonNumber: Int) {
            switch buttonNumber {
            case 3: self = .back
            case 4: self = .forward
            default: return nil
            }
        }
    }

    nonisolated enum Route: Equatable, Sendable {
        /// The browser tab under the pointer walks its history.
        case page(Button)
        /// Go Back or Go Forward.
        case history(Button)
        /// Not a side button, turned off, or over a view that forwards buttons: the event goes on.
        case pass

        static func of(_ button: Button?, enabled: Bool, overForwardingView: Bool, overBrowser: Bool) -> Route {
            guard let button, enabled, !overForwardingView else { return .pass }
            return overBrowser ? .page(button) : .history(button)
        }
    }

    /// The route each held button chose on its press. The release follows it even when the
    /// pointer moved or control mode changed in between, so a press that went to a remote host
    /// never navigates on its release, and a release with no press of ours (pressed in another
    /// app) passes on.
    struct Presses {
        private var held: [Button: Held] = [:]

        struct Held {
            var route: Route
            weak var browser: BrowserChromeView?
        }

        mutating func press(_ button: Button, route: Route, browser: BrowserChromeView?) {
            held[button] = Held(route: route, browser: browser)
        }

        mutating func release(_ button: Button) -> Held? {
            held.removeValue(forKey: button)
        }
    }

    private var monitor: Any?
    private var presses = Presses()
    private var history: (Button) -> Void = { _ in }

    public init() {}

    /// Starts watching the buttons; `history` runs the app's Go Back or Go Forward.
    public func start(history: @escaping (Button) -> Void) {
        guard monitor == nil else { return }
        self.history = history
        // AppKit calls a local monitor on the main thread (the module's isolation), like
        // `CEFLinkClickTracker`.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let button = Button(buttonNumber: event.buttonNumber) else { return event }
        if event.type == .otherMouseUp {
            guard let held = presses.release(button) else { return event }
            switch held.route {
            case .pass:
                return event
            case .page(let button):
                held.browser?.perform(button == .back ? .goBack : .goForward)
            case .history(let button):
                history(button)
            }
            return nil
        }
        guard let window = event.window else {
            presses.press(button, route: .pass, browser: nil)
            return event
        }
        let target = Target(window: window, screenPoint: window.convertPoint(toScreen: event.locationInWindow))
        let route = Route.of(button, enabled: NavigationTunables.mouseSideButtons.value,
                             overForwardingView: target.forwardsButtons, overBrowser: target.browser != nil)
        presses.press(button, route: route, browser: target.browser)
        return route == .pass ? event : nil
    }

    /// What is under the pointer: the browser tab, or a view that takes every mouse button.
    struct Target {
        var browser: BrowserChromeView?
        var forwardsButtons = false

        init(window: NSWindow, screenPoint: CGPoint) {
            // The press's own window first (a cmux window), then the window holding a page window.
            for candidate in [window, window.parent].compactMap(\.self) {
                guard let content = candidate.contentView else { continue }
                let point = candidate.convertPoint(fromScreen: screenPoint)
                var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                while let current = view {
                    if let chrome = current as? BrowserChromeView {
                        browser = chrome
                        return
                    }
                    if let forwarding = current as? any MouseButtonForwarding {
                        forwardsButtons = forwarding.forwardsMouseButtons
                        return
                    }
                    view = current.superview
                }
            }
        }
    }
}
