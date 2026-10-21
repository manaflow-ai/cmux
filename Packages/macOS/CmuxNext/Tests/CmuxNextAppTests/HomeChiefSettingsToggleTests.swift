import AppKit
@testable import CmuxNextHomeEngine
import Testing

/// `home.toggleChiefSettings` (the palette, `cmux action run`) opens the Chief Settings of the
/// front window's Home only. It reached every Home on screen, so with Chiefs in two windows one
/// palette run opened two popovers.
@MainActor @Suite struct HomeChiefSettingsToggleTests {
    static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func theKeyWindowTakesTheToggle() {
        let (key, other) = (Self.window(), Self.window())
        #expect(HomeChiefSettingsPopover.toggleTarget(key: key, ordered: [other, key]) === key)
    }

    /// With no key window (a CLI run while another app is in front) the frontmost visible window
    /// takes it, and with none on screen no Home does.
    @Test func withoutAKeyWindowTheFrontVisibleOneTakesIt() {
        let (hidden, shown) = (Self.window(), Self.window())
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: [hidden]) == nil)
        shown.orderFrontRegardless()
        defer { shown.orderOut(nil) }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: nil, ordered: [hidden, shown]) === shown)
    }

    /// The open popover is a child panel with the keys: it stands for its window, so a second
    /// toggle reaches the Home that opened it and closes it.
    @Test func aChildPanelWithTheKeysStandsForItsWindow() {
        let (home, popover) = (Self.window(), Self.window())
        home.addChildWindow(popover, ordered: .above)
        defer { home.removeChildWindow(popover) }
        #expect(HomeChiefSettingsPopover.toggleTarget(key: popover, ordered: []) === home)
    }

    @Test func onlyTheHomeInTheTargetWindowAnswers() {
        let (front, back) = (Self.window(), Self.window())
        let target = ObjectIdentifier(front)
        #expect(HomeChiefSettingsPopover.answersToggle(for: target, in: front))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: target, in: back))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: target, in: nil))
        #expect(!HomeChiefSettingsPopover.answersToggle(for: nil, in: front))
    }
}
