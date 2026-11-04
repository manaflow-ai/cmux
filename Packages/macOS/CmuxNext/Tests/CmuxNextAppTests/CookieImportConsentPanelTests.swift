import AppKit
@testable import CmuxNextCookieImport
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The consent panel before an agent's cookie import reads another browser
/// (`cmux browser import-cookies`, review of #32983): only the person at this
/// Mac answers Allow. A screen-reading agent cannot see the panel (it is out
/// of screen capture and screen sharing), and no automation can press Allow:
/// not an Accessibility press, not a programmatic click, not Return. Deny and
/// Escape stay easy.
@MainActor @Suite(.serialized, .closesItsWindows) struct CookieImportConsentPanelTests {
    static let request = CookieImportRequest(requester: CookieImportRequester(kind: .agentChat, name: "a49 · cookies"),
                                             reason: "Sign in to GitHub for the pull request", source: "Google Chrome · Work",
                                             sourceIsSafari: false, domains: ["github.com"], target: "Default")

    static func parent() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    }

    /// Waits until the panel shows on `parent` and returns its window.
    static func shown(_ consent: CookieImportConsentPanel, on parent: NSWindow) async throws -> NSWindow {
        for _ in 0..<1000 where !consent.isShown { await Task.yield() }
        try #require(consent.isShown)
        let panel = try #require(parent.childWindows?.first)
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    static func find(_ view: NSView?, id: String) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == id { return view }
        for subview in view.subviews {
            if let found = find(subview, id: id) { return found }
        }
        return nil
    }

    @Test func thePanelIsLeftOutOfScreenCaptureAndScreenSharing() async throws {
        _ = NSApplication.shared
        let parent = Self.parent()
        let consent = CookieImportConsentPanel(request: Self.request, onShowRequester: nil)
        let answer = Task { await consent.ask(on: parent, limit: .seconds(30)) }
        defer { consent.panel.closeAfterTest(); parent.closeAfterTest() }
        let panel = try await Self.shown(consent, on: parent)
        #expect(panel.sharingType == .none, "a screenshot, a recording or an agent's capture never holds Allow")
        consent.answer(.deny)
        #expect(await answer.value == .deny)
    }

    @Test func noAutomationPressesAllowAndDenyStaysEasy() async throws {
        _ = NSApplication.shared
        let parent = Self.parent()
        let consent = CookieImportConsentPanel(request: Self.request, onShowRequester: nil)
        let answer = Task { await consent.ask(on: parent, limit: .seconds(30)) }
        defer { consent.panel.closeAfterTest(); parent.closeAfterTest() }
        let panel = try await Self.shown(consent, on: parent)
        let allow = try #require(Self.find(panel.contentView, id: CookieImportConsentPanel.accessibilityID + ".allow") as? NSButton)
        let deny = try #require(Self.find(panel.contentView, id: CookieImportConsentPanel.accessibilityID + ".deny") as? NSButton)
        // An Accessibility press (any process with the Accessibility permission, a computer-use agent) and a
        // programmatic click (Allow's action, the Space key on a focused Allow) allow nothing.
        _ = allow.accessibilityPerformPress()
        allow.performClick(nil)
        // Return allows nothing either: a consent prompt never allows on a key.
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        _ = panel.performKeyEquivalent(with: returnKey)
        for _ in 0..<50 { await Task.yield() }
        #expect(consent.isShown, "the panel still waits for the person")
        // Deny stays one press away, by anyone: denying grants nothing.
        deny.performClick(nil)
        #expect(await answer.value == .deny)
        #expect(!consent.isShown)
    }

    @Test func theButtonsAreStandardDialogButtonsAndAllowHasNoKey() async throws {
        _ = NSApplication.shared
        let parent = Self.parent()
        let consent = CookieImportConsentPanel(request: Self.request, onShowRequester: {})
        let answer = Task { await consent.ask(on: parent, limit: .seconds(30)) }
        defer { consent.panel.closeAfterTest(); parent.closeAfterTest() }
        let panel = try await Self.shown(consent, on: parent)
        let id = CookieImportConsentPanel.accessibilityID
        let allow = try #require(Self.find(panel.contentView, id: id + ".allow") as? CmuxDialogButtonView)
        let deny = try #require(Self.find(panel.contentView, id: id + ".deny") as? CmuxDialogButtonView)
        #expect(Self.find(panel.contentView, id: id + ".showChat") is CmuxDialogButtonView)
        #expect(allow.button.role == .default && allow.keyHint == nil && allow.keyEquivalent.isEmpty,
                "Allow has the default look and no key: a consent prompt never allows on Return")
        #expect(deny.keyHint == .escape && deny.keyEquivalent == "\u{1b}", "Escape denies")
        consent.answer(.deny)
        #expect(await answer.value == .deny)
    }

    /// Allow answers only the person's own click on Allow, read from the click's events in the panel's
    /// dispatch: not a click another process posts (the strict HID check refuses it), not one pressed on
    /// Allow and released elsewhere, and, as Chrome's permission prompts guard, not a click that begins
    /// right after the panel shows or moves, or right after the person's other click. Then the person's
    /// click allows, once, even right after another process's click.
    @Test func onlyThePersonsOwnClickOnAllowAllows() async throws {
        _ = NSApplication.shared
        let parent = Self.parent()
        var genuine: Set<Int> = []
        let consent = CookieImportConsentPanel(request: Self.request, onShowRequester: nil,
                                               isPersonEvent: { genuine.contains($0.eventNumber) })
        let answer = Task { await consent.ask(on: parent, limit: .seconds(30)) }
        defer { consent.panel.closeAfterTest(); parent.closeAfterTest() }
        _ = try await Self.shown(consent, on: parent)
        let window = consent.panel
        let allow = try #require(consent.allowButton)
        let deny = try #require(Self.find(window.contentView, id: CookieImportConsentPanel.accessibilityID + ".deny"))
        let delay = window.personClick.activationDelay
        #expect(delay >= 0.2, "a click aimed at what was there before the panel is not taken")
        // Later than any real show, move or occlusion change while the test runs (each arms at the uptime then).
        let base = ProcessInfo.processInfo.systemUptime + 1000
        window.personClick.shown(at: base)
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        var number = 0
        let event = { (type: NSEvent.EventType, at: NSPoint, time: TimeInterval) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: time,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                                   clickCount: 1, pressure: 0))
        }
        var current: NSEvent?
        window.personClick.eventInHand = { current }
        /// A click begun at `time`: the mouse-down on `down`, then the mouse-up on `up` inside its dispatch (the
        /// button's tracking loop), with Allow's action pressed there too.
        let click = { (down: NSView, up: NSView, person: Bool, time: TimeInterval) throws in
            let pressed = try event(.leftMouseDown, center(down), time), released = try event(.leftMouseUp, center(up), time + 0.05)
            if person { genuine.formUnion([pressed.eventNumber, released.eventNumber]) }
            current = pressed
            window.dispatch(pressed) {
                current = released
                allow.performClick(nil)
            }
        }
        try click(allow, allow, true, base + delay / 2) // right after the panel showed
        try click(allow, allow, false, base + 4 * delay) // another process's posted click
        try click(allow, deny, true, base + 8 * delay) // pressed on Allow, released on Deny
        try click(deny, allow, true, base + 12 * delay) // pressed on Deny, released on Allow
        try click(allow, deny, true, base + 16 * delay)
        try click(allow, allow, true, base + 16.5 * delay) // right after the person's other click (a double click)
        window.personClick.shown(at: base + 20 * delay) // the panel moved under the pointer
        try click(allow, allow, true, base + 20.5 * delay)
        for _ in 0..<50 { await Task.yield() }
        #expect(consent.isShown, "no click so far allows")
        // Another process's clicks just before never hold the person's Allow off.
        try click(allow, allow, false, base + 23.8 * delay)
        try click(allow, allow, true, base + 24 * delay)
        #expect(await answer.value == .allow)
        #expect(!consent.isShown)
    }

    /// A move of the panel arms Chrome's guard again: a click right after the panel moved under the pointer
    /// (an Accessibility client set its position, or its parent moved) is not taken; the next one is.
    @Test func aClickRightAfterThePanelMovesIsNotTaken() async throws {
        _ = NSApplication.shared
        let parent = Self.parent()
        let consent = CookieImportConsentPanel(request: Self.request, onShowRequester: nil, isPersonEvent: { _ in true })
        let answer = Task { await consent.ask(on: parent, limit: .seconds(30)) }
        defer { consent.panel.closeAfterTest(); parent.closeAfterTest() }
        _ = try await Self.shown(consent, on: parent)
        let window = consent.panel
        let allow = try #require(consent.allowButton)
        let delay = window.personClick.activationDelay
        let base = ProcessInfo.processInfo.systemUptime + 1000
        window.personClick.shown(at: base)
        let at = allow.convert(NSPoint(x: allow.bounds.midX, y: allow.bounds.midY), to: nil)
        var number = 0
        let event = { (type: NSEvent.EventType, time: TimeInterval) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: time,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                                   clickCount: 1, pressure: 0))
        }
        var current: NSEvent?
        window.personClick.eventInHand = { current }
        /// The person's click on Allow begun at `time`, its mouse-up inside the mouse-down's dispatch.
        let click = { (time: TimeInterval) throws in
            let pressed = try event(.leftMouseDown, time), released = try event(.leftMouseUp, time + 0.05)
            current = pressed
            window.dispatch(pressed) {
                current = released
                allow.performClick(nil)
            }
        }
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 40, y: window.frame.minY + 40))
        try click(base + 4 * delay) // the first click after the move
        for _ in 0..<50 { await Task.yield() }
        #expect(consent.isShown, "a click right after the panel moved is not taken")
        try click(base + 8 * delay)
        #expect(await answer.value == .allow)
    }

    /// A palette or Import card run skips the panel only for the person's own click or key that just
    /// started it: not another process's, not a mouse move, and not an old event (an Accessibility press
    /// makes no event, so the event in dispatch is an older one).
    @Test func aPersonsRunIsOnlyOneThePersonsOwnRecentInputStarted() throws {
        let event = { (type: NSEvent.EventType, time: TimeInterval) throws -> NSEvent in
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0,
                                            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        }
        let person: @MainActor (NSEvent) -> Bool = { _ in true }
        #expect(CookieImportService.startedByPerson(try event(.leftMouseUp, 99.5), now: 100, isPerson: person))
        #expect(!CookieImportService.startedByPerson(try event(.leftMouseUp, 99.5), now: 100, isPerson: { _ in false }),
                "another process's click")
        #expect(!CookieImportService.startedByPerson(try event(.mouseMoved, 99.9), now: 100, isPerson: person), "a mouse move")
        #expect(!CookieImportService.startedByPerson(try event(.leftMouseUp, 90), now: 100, isPerson: person), "an old click")
        #expect(!CookieImportService.startedByPerson(nil, now: 100, isPerson: person), "no event")
    }
}
