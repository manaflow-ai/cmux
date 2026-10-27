import AppKit
import CmuxNextInput

/// The last mouse-up on a Chromium page, recorded by the app (the shim
/// reports a disposition but not the click's modifiers).
nonisolated struct CEFLinkClickRecord: Equatable, Sendable {
    var gesture: BrowserLinkGesture
    /// `NSEvent.timestamp` (seconds since boot).
    var timestamp: TimeInterval
}

/// A shown Chromium page a click can land on: its pane's host view, on
/// screen, in the cmux window that holds it.
nonisolated struct CEFClickTarget: Equatable, Sendable {
    var browser: Int32
    /// The cmux window of the host view (the page window's parent).
    var hostWindow: ObjectIdentifier
    /// The host view's frame, screen coordinates.
    var frame: CGRect
    /// Native UI over the page (find bar, dividers), screen coordinates.
    var occlusions: [CGRect] = []
}

/// The runtime's link click state: the user's mapping and the last mouse-up
/// (Chromium's dispositions do not carry the click's modifiers). A popup's
/// target URL arrives with its tab's AFTER_CREATED (`CEFCreatedBy.url`).
@MainActor
final class CEFLinkClickTracker {
    /// cmux.json `browser.links.*`, set by the App.
    var mapping: BrowserLinkClickMapping = .chrome
    /// The last left or middle mouse-up on each Chromium page, by browser id.
    private(set) var clicks: [Int32: CEFLinkClickRecord] = [:]
    private var subscription: InputSubscription?
    /// The tap `subscription` hears.
    private weak var input: InputEventTap?
    /// The pages a click can land on now (the runtime's shown tabs).
    private var targets: () -> [CEFClickTarget] = { [] }
    /// A mouse down or key down on page `browser`: a fresh user gesture
    /// (the tab's `AutomaticDownloadGate`). The shim reports no gesture
    /// for downloads, so the app's own input events are the signal, as
    /// for WebKit (`WebKitWebView`).
    var onGesture: (Int32) -> Void = { _ in }

    /// The context for placing a tab Chromium wants to open now.
    func context() -> CEFLinkContext {
        CEFLinkContext(mapping: mapping, clicks: clicks, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Records left and middle mouse-ups on Chromium pages, per page, and
    /// reports mouse downs and key downs on them (`onGesture`). A
    /// Chromium page draws in its own child window over its pane's host
    /// view; a click in a cmux window itself (strip, sidebar, omnibar) or
    /// on native UI over the page records nothing (`CEFLinkClicks.browser`).
    ///
    /// It hears `input`, the app's input tap, as a `.standard` intercept that
    /// always passes: where AppKit's local monitor ran, after the key router
    /// and the earlier intercepts. A shortcut the router takes or a click an
    /// earlier intercept consumes never reaches the page, so it is no gesture
    /// and no link click, as Chrome resets its download limiter only on input
    /// sent to the renderer (`chrome/browser/download/download_request_limiter.cc`,
    /// `TabDownloadState::DidGetUserInteraction`), not on accelerators taken in
    /// `PreHandleKeyboardEvent`. A later call with another tap moves the
    /// subscription to it; one with the same tap does nothing.
    func startRecordingClicks(input: InputEventTap, targets: @escaping () -> [CEFClickTarget]) {
        guard subscription == nil || self.input !== input else { return }
        self.targets = targets
        self.input = input
        subscription = input.subscribe(class: [.button, .key], phase: .intercept(order: .standard)) { [weak self] event in
            self?.record(event)
            return .pass
        }
    }

    /// Whether clicks are recorded now.
    var isRecording: Bool { subscription != nil }

    /// The events the tracker reads: left and other mouse-ups (the click),
    /// every mouse-down and key-down (a fresh gesture).
    static func records(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseUp, .otherMouseUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown: true
        default: false
        }
    }

    func record(_ event: NSEvent) {
        guard Self.records(event.type), let window = event.window else { return }
        // Keys go to the focused page window, whose center is on its page.
        let point = event.type == .keyDown ? CGPoint(x: window.frame.midX, y: window.frame.midY)
            : window.convertPoint(toScreen: event.locationInWindow)
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: point, targets: targets()) else { return }
        guard event.type == .leftMouseUp || event.type == .otherMouseUp else { return onGesture(browser) }
        let button = event.type == .otherMouseUp ? event.buttonNumber : 0
        clicks[browser] = CEFLinkClickRecord(gesture: BrowserLinkGesture(flags: event.modifierFlags, button: button),
                                             timestamp: event.timestamp)
    }

    func forget(opener: Int32) {
        clicks[opener] = nil
    }
}
