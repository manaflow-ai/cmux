import AppKit
@testable import CmuxNextCookieImport
import Testing

/// The consent panel before an agent's cookie import reads another browser
/// (`cmux browser import-cookies`, review of #32983): only the person at this
/// Mac answers Allow. A screen-reading agent cannot see the panel (it is out
/// of screen capture and screen sharing), and no automation can press Allow:
/// not an Accessibility press, not a programmatic click, not Return. Deny and
/// Escape stay easy.
@MainActor @Suite(.serialized) struct CookieImportConsentPanelTests {
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
}
