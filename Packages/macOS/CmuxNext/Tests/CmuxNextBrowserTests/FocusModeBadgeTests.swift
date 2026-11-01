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

    @Test func clickingBadgeAsksHostToLeave() {
        let (chrome, window) = chrome()
        defer { window.close() }
        var presses = 0
        chrome.onFocusModeBadgePress = { presses += 1 }
        chrome.showsFocusModeIndicator = true
        #expect(chrome.addressBar.focusModeBadgeView.accessibilityPerformPress())
        #expect(presses == 1)
    }

    /// With fades off (`ui.animations.feedback`, or the master switch) the badge appears in the
    /// same frame. Reduce Motion alone keeps fades (shortened to a crossfade, `MotionPolicy`), so
    /// pinning it left this to the host: where the window has an awake screen the fade ran and
    /// alpha read 0 (aws-m4pro-8 and -9 every run).
    @Test func fadesOffShowBadgeAtOnce() {
        let design = DesignSettings.shared
        let saved = design.disabledAnimationCategories
        design.disabledAnimationCategories.insert(.feedback)
        defer { design.disabledAnimationCategories = saved }
        let (chrome, window) = chrome()
        defer { window.close() }
        chrome.showsFocusModeIndicator = true
        #expect(chrome.addressBar.focusModeBadgeView.alphaValue == 1)
        #expect(!chrome.addressBar.focusModeBadgeView.isHidden)
    }

    /// The badge is a lit chip in the theme's accent, never orange (Leo 2026-10-21: "the accent is
    /// never orange"). It was `systemOrange`, a color no theme sets.
    @Test func badgeUsesTheThemeAccentNotOrange() {
        let (chrome, window) = chrome()
        defer { window.close() }
        chrome.showsFocusModeIndicator = true
        let badge = chrome.addressBar.focusModeBadgeView
        badge.updateLayer()
        let shown = badge.shownTextColor?.usingColorSpace(.sRGB)
        let lit = badge.performWithTheme { Palette.litGlyph }.usingColorSpace(.sRGB)
        let orange = NSColor.systemOrange.usingColorSpace(.sRGB)
        #expect(shown != nil)
        #expect(shown != orange)
        #expect(shown == lit)
    }
}
