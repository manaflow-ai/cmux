import AppKit
import CmuxNextDesign
public import CmuxNextInput

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
///
/// The buttons come from the app's input tap as one `.button` intercept (where AppKit's local monitors
/// ran), as Chrome takes them in its window's own event handling, not from a process-wide hook
/// (`chrome/browser/ui/views/frame/browser_root_view.cc`: `OnMousePressed` keeps the back and
/// forward buttons, `OnMouseReleased` runs `IDC_BACK` / `IDC_FORWARD`).
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

    private let input: InputEventTap
    /// What is under a press: its window's view tree (``Target/under(_:)``), a test's fixed answer.
    private let locate: (NSEvent) -> Target?
    private var subscription: InputSubscription?
    private var presses = Presses()
    private var history: (Button) -> Void = { _ in }

    /// Side buttons that hear `input`, the app's one input tap, once started.
    public convenience init(input: InputEventTap) {
        self.init(input: input, locate: Target.under)
    }

    /// Side buttons that find what is under a press with `locate` (nil: the press has no window).
    init(input: InputEventTap, locate: @escaping (NSEvent) -> Target?) {
        self.input = input
        self.locate = locate
    }

    /// Starts hearing the buttons; `history` runs the app's Go Back or Go Forward.
    public func start(history: @escaping (Button) -> Void) {
        guard subscription == nil else { return }
        self.history = history
        subscription = input.subscribe(class: .button, phase: .intercept(order: .standard)) { [weak self] event in
            self?.handle(event) ?? .pass
        }
    }

    /// Stops hearing the buttons (a held press's release then passes on).
    public func stop() {
        subscription = nil
        presses = Presses()
    }

    /// Whether the buttons are heard now.
    public var isStarted: Bool { subscription != nil }

    func handle(_ event: NSEvent) -> InputEventTap.InterceptResult {
        guard event.type == .otherMouseDown || event.type == .otherMouseUp,
              let button = Button(buttonNumber: event.buttonNumber) else { return .pass }
        if event.type == .otherMouseUp {
            guard let held = presses.release(button) else { return .pass }
            switch held.route {
            case .pass:
                return .pass
            case .page(let button):
                held.browser?.perform(button == .back ? .goBack : .goForward)
            case .history(let button):
                history(button)
            }
            return .consume
        }
        guard let target = locate(event) else {
            presses.press(button, route: .pass, browser: nil)
            return .pass
        }
        let route = Route.of(button, enabled: NavigationTunables.mouseSideButtons.value,
                             overForwardingView: target.forwardsButtons, overBrowser: target.browser != nil)
        presses.press(button, route: route, browser: target.browser)
        return route == .pass ? .pass : .consume
    }

    /// What is under the pointer: the browser tab, or a view that takes every mouse button.
    struct Target {
        var browser: BrowserChromeView?
        var forwardsButtons = false

        init(browser: BrowserChromeView? = nil, forwardsButtons: Bool = false) {
            self.browser = browser
            self.forwardsButtons = forwardsButtons
        }

        /// What is under `event`'s pointer in its window; nil when it has no window.
        static func under(_ event: NSEvent) -> Target? {
            guard let window = event.window else { return nil }
            return Target(window: window, screenPoint: window.convertPoint(toScreen: event.locationInWindow))
        }

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
