import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// Mouse buttons 4 and 5 are Back and Forward (plans/cmux-next/history.md 4.2), as in Chrome,
/// Safari, Claude and Codex. Over a browser tab (its page or its toolbar) they walk that tab's
/// history, through the same `BrowserChromeView` command as `browserBack`; anywhere else they run
/// Go Back and Go Forward (`focusHistoryBack`: the shown page's own history, then the location
/// trail, 4.2b). A view that forwards every button to something else (a remote desktop in control
/// mode) keeps them. The press is consumed and the release navigates, as in Chrome.
///
/// A Chromium page draws in its own child window, so a press on it arrives in that window; the
/// browser tab is found in the cmux window that holds it (`window.parent`).
@MainActor
final class MouseSideButtons {
    nonisolated enum Button: Equatable, Sendable {
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

    private var monitor: Any?

    func start(services: AppServices) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak services] event in
            guard Thread.isMainThread, let services else { return event } // main-proof: returns the event off the main thread
            return MainActor.assumeIsolated { Self.handle(event, services: services) } // main-proof: guarded by Thread.isMainThread above
        }
    }

    private static func handle(_ event: NSEvent, services: AppServices) -> NSEvent? {
        guard let button = Button(buttonNumber: event.buttonNumber) else { return event }
        guard let window = event.window else { return event }
        let target = Target(window: window, screenPoint: window.convertPoint(toScreen: event.locationInWindow))
        switch Route.of(button, enabled: NavigationTunables.mouseSideButtons.value,
                        overForwardingView: target.forwardsButtons, overBrowser: target.browser != nil) {
        case .pass:
            return event
        case .page(let button):
            if event.type == .otherMouseUp { target.browser?.perform(button == .back ? .goBack : .goForward) }
        case .history(let button):
            if event.type == .otherMouseUp { _ = services.registry.perform(button == .back ? "focusHistoryBack" : "focusHistoryForward") }
        }
        return nil
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
                    if current.responds(to: Self.forwardsSelector) {
                        forwardsButtons = current.value(forKey: "cmuxForwardsMouseButtons") as? Bool ?? false
                        return
                    }
                    view = current.superview
                }
            }
        }

        /// `-cmuxForwardsMouseButtons`: a view that may send every mouse button on (the remote desktop
        /// view in control mode); its value says whether it does now.
        static let forwardsSelector = NSSelectorFromString("cmuxForwardsMouseButtons")
    }
}
