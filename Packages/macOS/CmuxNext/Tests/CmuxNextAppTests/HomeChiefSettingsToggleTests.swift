import AppKit
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Testing

/// `home.toggleChiefSettings` (the palette, `cmux action run`) opens the Chief Settings of the
/// front window's Home only. It reached every Home on screen, so with Chiefs in two windows one
/// palette run opened two popovers.
@MainActor @Suite(.closesItsWindows) struct HomeChiefSettingsToggleTests {
    static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func theKeyWindowTakesTheToggle() {
        let (key, other) = (Self.window(), Self.window())
        defer {
            key.closeAfterTest()
            other.closeAfterTest()
        }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: key, ordered: [other, key]) === key)
    }

    /// With no key window (a CLI run while another app is in front) the frontmost visible window
    /// takes it, and with none on screen no Home does.
    @Test func withoutAKeyWindowTheFrontVisibleOneTakesIt() {
        let (hidden, shown) = (Self.window(), Self.window())
        defer {
            hidden.closeAfterTest()
            shown.closeAfterTest()
        }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: [hidden]) == nil)
        shown.orderFrontRegardless()
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: [hidden, shown]) === shown)
    }

    /// With no key window, a visible child window in front (Chromium's page window, an overlay
    /// panel) stands for the window it belongs to. AppKit lists a child window before its parent
    /// when the app is not active, so a toggle run from the CLI with cmux in the background (every
    /// capture slot) reached the page window, no Home answered, and the popover never opened.
    @Test func withoutAKeyWindowAChildInFrontStandsForItsWindow() {
        let (home, page) = (Self.window(), Self.window())
        home.orderFrontRegardless()
        home.addChildWindow(page, ordered: .above)
        defer {
            home.removeChildWindow(page)
            page.closeAfterTest()
            home.closeAfterTest()
        }
        #expect(page.isVisible)
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: [page, home]) === home)
    }

    /// The open popover is a child panel with the keys: it stands for its window, so a second
    /// toggle reaches the Home that opened it and closes it.
    @Test func aChildPanelWithTheKeysStandsForItsWindow() {
        let (home, popover) = (Self.window(), Self.window())
        home.addChildWindow(popover, ordered: .above)
        defer {
            home.removeChildWindow(popover)
            popover.closeAfterTest()
            home.closeAfterTest()
        }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: popover, ordered: []) === home)
    }

    @Test func onlyTheHomeInTheTargetWindowAnswers() {
        let (front, back) = (Self.window(), Self.window())
        defer {
            front.closeAfterTest()
            back.closeAfterTest()
        }
        let target = ObjectIdentifier(front)
        #expect(HomeChiefSettingsPopover.answersToggle(for: target, in: front))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: target, in: back))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: target, in: nil))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: nil, in: front))
    }
}
