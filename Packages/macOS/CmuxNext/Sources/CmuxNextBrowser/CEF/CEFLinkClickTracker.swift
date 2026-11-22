import AppKit
import CmuxNextCompat

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
    /// Menus opening and closing (the app's one seam for them), kept while clicks are recorded.
    private var menus: MenuTracking?
    /// The page the person last pressed, released or typed on, with no input elsewhere since
    /// (another pane, the sidebar, native UI over the page): the one a menu opening now belongs to.
    private(set) var lastPressed: Int32?
    /// The page whose input opened the menu tracking now: the only page its close credits.
    private(set) var menuOwner: Int32?
    /// The pages a click can land on now (the runtime's shown tabs).
    var targets: () -> [CEFClickTarget] = { [] }
    /// A mouse down, mouse up or key down on page `browser`: a fresh user
    /// gesture (the tab's `AutomaticDownloadGate`, an app page's write). The
    /// shim reports no gesture for downloads, so the app's own input events
    /// are the signal, as for WebKit, whose page views count the up too
    /// (`PageWKWebView`): a page that saves on a drag's release (Settings >
    /// Menus) acts on the person's input after a drag of any length.
    var onGesture: (Int32) -> Void = { _ in }
    /// SECURITY: whether an input event is the person's own (the app's strict HID-system check, `PersonInputCheck`,
    /// set by the app). A click or key another process posts (a computer-use agent, a script) is not; with none set,
    /// no event is.
    var isPerson: @MainActor (NSEvent) -> Bool = { _ in false }
    /// The person's own mouse down, mouse up or key on page `browser` (``isPerson``): the page's WebAuthn is theirs
    /// again (``CEFTab/allowWebAuthnForPerson()``).
    var onPersonInput: (Int32) -> Void = { _ in }

    /// The context for placing a tab Chromium wants to open now.
    func context() -> CEFLinkContext {
        CEFLinkContext(mapping: mapping, clicks: clicks, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Records left and middle mouse-ups on Chromium pages, per page, and
    /// reports mouse downs, mouse ups and key downs on them (`onGesture`). A
    /// Chromium page draws in its own child window over its pane's host
    /// view; a click in a cmux window itself (strip, sidebar, omnibar) or
    /// on native UI over the page records nothing (`CEFLinkClicks.browser`).
    /// A local monitor sees the event only; it never consumes it.
    func startRecordingClicks(targets: @escaping () -> [CEFClickTarget]) {
        guard monitor == nil else { return }
        self.targets = targets
        let events: NSEvent.EventTypeMask = [.leftMouseUp, .otherMouseUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.record(event)
            return event
        }
        // A choice in a menu Chromium itself shows for the page (a <select>'s popup) is made in the
        // menu's own tracking loop, which the monitor above never sees: the click that opened it
        // is long spent by the time the page acts on the choice. The menu ending its tracking is
        // posted at once, before the choice reaches the page.
        let menus = MenuTracking()
        menus.subscribe { [weak self] change in
            switch change {
            case .began(let menu): self?.recordMenuOpened(menu)
            case .ended(let menu): self?.recordMenuChoice(menu)
            }
        }
        self.menus = menus
    }

    /// `menu` began tracking: it belongs to the page the person's last input was on, if no input
    /// went elsewhere since (a press in the sidebar that opens the sidebar's menu clears that page).
    /// A menu of the app's menu bar belongs to no page.
    func recordMenuOpened(_ menu: NSMenu) {
        menuOwner = Self.inMenuBar(menu) ? nil : lastPressed
    }

    /// `menu` closed (a row chosen, or dismissed): the person's gesture on the page whose input
    /// opened it (``recordMenuOpened(_:)``), as the host's own Chromium menu counts its close. The
    /// page comes from that press, never the key window's middle: in a split window the middle is
    /// another pane's page (a <select> in Settings beside a chat was refused). A menu of the app's
    /// menu bar, or one no input on a page opened, is no page's gesture.
    func recordMenuChoice(_ menu: NSMenu?) {
        let owner = menuOwner
        menuOwner = nil
        guard let menu, !Self.inMenuBar(menu), let owner else { return }
        onGesture(owner)
    }

    static func inMenuBar(_ menu: NSMenu) -> Bool {
        var top = menu
        while let parent = top.supermenu { top = parent }
        return top === NSApp?.mainMenu
    }

    func record(_ event: NSEvent) {
        guard let window = event.window else { return recordInputOutsidePages() }
        // Keys go to the focused page window, whose center is on its page.
        let point = event.type == .keyDown ? CGPoint(x: window.frame.midX, y: window.frame.midY)
            : window.convertPoint(toScreen: event.locationInWindow)
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: point, targets: targets()) else { return recordInputOutsidePages() }
        record(event.type, on: browser, button: event.buttonNumber, flags: event.modifierFlags, timestamp: event.timestamp,
               byPerson: isPerson(event))
    }

    /// A press, release or key outside every Chromium page (another pane, the sidebar, native UI
    /// over a page): a menu it opens is no page's, so the page pressed last stops owning menus.
    func recordInputOutsidePages() {
        lastPressed = nil
    }

    /// A VoiceOver press (``ChromiumAccessibilityPress``) on an element in `window`, `frame` its
    /// screen frame: the person's gesture on the page under the element's center, as a key down is
    /// on the page it reaches. It is no click (no modifiers, no button), so the page's last click
    /// stays. An element whose window is the cmux window counts on the page window over its center.
    func recordAccessibilityPress(in window: NSWindow, frame: CGRect?) {
        let point = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        let page = window.parent == nil ? window.childWindows?.first { child in point.map(child.frame.contains) ?? false } ?? window : window
        let center = point ?? CGPoint(x: page.frame.midX, y: page.frame.midY)
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(page), parent: page.parent.map(ObjectIdentifier.init),
                                                  at: center, targets: targets()) else { return }
        onGesture(browser)
    }

    /// An input event of `type` on page `browser`: every press, release and key is the person's
    /// gesture (the release too: a page that saves on a drag's release acts on it); a left or
    /// middle release is also the page's last click. `byPerson`: the person's own input (``isPerson``).
    func record(_ type: NSEvent.EventType, on browser: Int32, button: Int, flags: NSEvent.ModifierFlags, timestamp: TimeInterval,
                byPerson: Bool) {
        onGesture(browser)
        lastPressed = browser
        if byPerson { onPersonInput(browser) }
        guard type == .leftMouseUp || type == .otherMouseUp else { return }
        clicks[browser] = CEFLinkClickRecord(gesture: BrowserLinkGesture(flags: flags, button: type == .otherMouseUp ? button : 0),
                                             timestamp: timestamp)
    }

    func forget(opener: Int32) {
        clicks[opener] = nil
        if lastPressed == opener { lastPressed = nil }
        if menuOwner == opener { menuOwner = nil }
    }
}
