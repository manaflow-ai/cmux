import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Classic cmux shows browser focus mode as a toolbar chip ("Focus Mode", then "Esc again to
/// exit" after the first Escape) that leaves focus mode on click. cmux-next showed only a 2 pt
/// outline, so nothing said how to get out (Lawrence 2026-10-20).
@MainActor @Suite(.serialized, .closesItsWindows) struct FocusModeBadgeTests {
    private func chrome() -> (BrowserChromeView, NSWindow) {
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        // The test owns the window; closing must not also release it (an over-release crashed the suite).
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentView!.bounds
        window.contentView!.addSubview(chrome)
        chrome.layoutSubtreeIfNeeded()
        return (chrome, window)
    }

    @Test func badgeFollowsFocusModeAndExitArm() {
        let (chrome, window) = chrome()
        defer { window.close() }
        #expect(!chrome.addressBar.showsFocusModeBadge)
        chrome.showsFocusModeIndicator = true
        #expect(chrome.addressBar.showsFocusModeBadge)
        #expect(chrome.addressBar.focusModeBadgeText == Strings.focusModeActive)
        chrome.focusModeExitArmed = true
        #expect(chrome.addressBar.focusModeBadgeText == Strings.focusModeArmed)
        chrome.showsFocusModeIndicator = false
        #expect(!chrome.addressBar.showsFocusModeBadge)
        #expect(!chrome.focusModeExitArmed)
    }

    /// A press on the page's badge reaches the host's handler, the one the native chip ran.
    @Test func clickingBadgeAsksHostToLeave() {
        let (chrome, window) = chrome()
        defer { window.close() }
        var presses = 0
        chrome.onFocusModeBadgePress = { presses += 1 }
        chrome.showsFocusModeIndicator = true
        chrome.addressBar.handle(.focusModeBadge)
        #expect(presses == 1)
    }

    /// The badge reaches the toolbar page as its text in the pushed state; the page draws it as a
    /// lit chip in the theme's accent (Leo 2026-10-21: "the accent is never orange"), with the
    /// page's own motion gate.
    @Test func badgeTextIsPushedToThePage() {
        let (chrome, window) = chrome()
        defer { window.close() }
        chrome.showsFocusModeIndicator = true
        let badges = chrome.addressBar.badgesWire
        #expect((badges["focusMode"] as? [String: Any])?["text"] as? String == Strings.focusModeActive)
        chrome.showsFocusModeIndicator = false
        #expect(chrome.addressBar.badgesWire["focusMode"] is NSNull)
    }
}
