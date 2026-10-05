import AppKit

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
    private var monitor: Any?
    /// The pages a click can land on now (the runtime's shown tabs).
    private var targets: () -> [CEFClickTarget] = { [] }

    /// The context for placing a tab Chromium wants to open now.
    func context() -> CEFLinkContext {
        CEFLinkContext(mapping: mapping, clicks: clicks, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Records left and middle mouse-ups on Chromium pages, per page. A
    /// Chromium page draws in its own child window over its pane's host
    /// view; a click in a cmux window itself (strip, sidebar, omnibar) or
    /// on native UI over the page records nothing (`CEFLinkClicks.browser`).
    /// A local monitor sees the event only; it never consumes it.
    func startRecordingClicks(targets: @escaping () -> [CEFClickTarget]) {
        guard monitor == nil else { return }
        self.targets = targets
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .otherMouseUp]) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func record(_ event: NSEvent) {
        guard let window = event.window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: point, targets: targets()) else { return }
        let button = event.type == .otherMouseUp ? event.buttonNumber : 0
        clicks[browser] = CEFLinkClickRecord(gesture: BrowserLinkGesture(flags: event.modifierFlags, button: button),
                                             timestamp: event.timestamp)
    }

    func forget(opener: Int32) {
        clicks[opener] = nil
    }
}
