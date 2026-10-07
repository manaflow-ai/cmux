import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Sessions share a tab's web view but not its modifier keys: a Meta or
/// Shift one session holds must never turn another session's key, click or
/// drag into a chord (Meta+click opens a link in a new tab, Meta+V pastes).
/// Each key event and each automated mouse event carries only the modifiers
/// the session that sends it holds.
@MainActor
@Suite("Browser REPL modifier keys per session", .serialized)
struct BrowserReplModifierScopeTests {
    /// Records the key and modifier events WebKit's responder methods get.
    private final class RecordingWebView: WKWebView {
        var keyDowns: [NSEvent] = []
        var flagsChanges: [NSEvent] = []
        override func keyDown(with event: NSEvent) { keyDowns.append(event) }
        override func keyUp(with event: NSEvent) {}
        override func flagsChanged(with event: NSEvent) { flagsChanges.append(event) }
    }

    private func stroke(_ key: String, _ code: String, text: String? = nil) throws -> BrowserReplKeyStroke {
        try #require(try BrowserReplKeyStroke.resolve(key: key, code: code, text: text, modifiers: []))
    }

    @Test func aModifierOneSessionHoldsDoesNotReachAnotherSessionsKeys() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let meta = try stroke("Meta", "MetaLeft")
        let q = try stroke("q", "KeyQ", text: "q")
        #expect(webView.replayBrowserReplKeyStroke(meta, keyDown: true, heldBy: "holder") == .delivered)
        #expect(webView.replayBrowserReplKeyStroke(q, keyDown: true, heldBy: "other") == .delivered)
        let delivered = try #require(webView.keyDowns.last)
        #expect(!delivered.modifierFlags.contains(.command), "another session's held Meta turned this session's key into a Meta chord")
        #expect(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: "other").isEmpty)

        // The holder's own keys still carry it.
        #expect(webView.replayBrowserReplKeyStroke(q, keyDown: true, heldBy: "holder") == .delivered)
        #expect(webView.keyDowns.last?.modifierFlags.contains(.command) == true)
        #expect(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: "holder").contains(.command))
    }

    /// Another session's modifier press reports only its own modifiers to
    /// the page, and a release by one session leaves the other's held.
    @Test func modifierEventsCarryOnlyTheSendingSessionsModifiers() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let meta = try stroke("Meta", "MetaLeft")
        let shift = try stroke("Shift", "ShiftLeft")
        #expect(webView.replayBrowserReplKeyStroke(meta, keyDown: true, heldBy: "holder") == .delivered)
        #expect(webView.replayBrowserReplKeyStroke(shift, keyDown: true, heldBy: "other") == .delivered)
        let shiftDown = try #require(webView.flagsChanges.last)
        #expect(shiftDown.modifierFlags.contains(.shift))
        #expect(!shiftDown.modifierFlags.contains(.command))
        #expect(webView.replayBrowserReplKeyStroke(shift, keyDown: false, heldBy: "other") == .delivered)
        #expect(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: "holder") == .command)
        webView.forgetBrowserReplModifier(meta, heldBy: "holder")
        #expect(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: "holder").isEmpty)
    }
}

/// The tab's record of held keys is per session too: a key two sessions
/// hold stays held for each until that session releases it.
@Suite struct BrowserReplHeldKeysPerSessionTests {
    @Test func theSameKeyHeldByTwoSessionsIsReleasedByEach() throws {
        var held = BrowserReplHeldKeys()
        let shift = try #require(try BrowserReplKeyStroke.resolve(key: "Shift", code: "ShiftLeft", text: nil, modifiers: []))
        held.record(shift, keyDown: true, sessionID: "first")
        held.record(shift, keyDown: true, sessionID: "second")
        #expect(held.releaseAll(heldBy: "first") == [shift], "a second session's press took the first session's held key")
        #expect(held.releaseAll(heldBy: "second") == [shift])
    }
}
