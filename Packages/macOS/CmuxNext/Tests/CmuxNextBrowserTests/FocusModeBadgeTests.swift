import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// Classic cmux shows browser focus mode as a toolbar chip ("Focus Mode", then "Esc again to
/// exit" after the first Escape) that leaves focus mode on click. cmux-next showed only a 2 pt
/// outline, so nothing said how to get out (Lawrence 2026-10-20).
@MainActor @Suite(.serialized) struct FocusModeBadgeTests {
    private func chrome() -> (BrowserChromeView, NSWindow) {
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
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

    @Test func clickingBadgeAsksHostToLeave() {
        let (chrome, window) = chrome()
        defer { window.close() }
        var presses = 0
        chrome.onFocusModeBadgePress = { presses += 1 }
        chrome.showsFocusModeIndicator = true
        #expect(chrome.addressBar.focusModeBadgeView.accessibilityPerformPress())
        #expect(presses == 1)
    }

    @Test func reduceMotionShowsBadgeAtOnce() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (chrome, window) = chrome()
        defer { window.close() }
        chrome.showsFocusModeIndicator = true
        #expect(chrome.addressBar.focusModeBadgeView.alphaValue == 1)
        #expect(!chrome.addressBar.focusModeBadgeView.isHidden)
    }
}
