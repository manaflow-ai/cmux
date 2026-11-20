import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Keyboard focus on a sidebar item is the theme's tint, never macOS's blue focus ring (cx-wqn5,
/// Leo's YouTube Music reference): the arrow-walked row takes the next tonal step over its resting
/// fill, one step past hover, and draws no system ring.
@MainActor
@Suite(.closesItsWindows)
struct SidebarKeyFocusTests {
    @Test func aKeyFocusedRowIsTintedNotRinged() {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        row.configure(SidebarItemInfo(title: "Home", symbol: "house"), style: .builtIn)
        #expect(row.focusRingType == .none)
        #expect(row.fill == nil)
        _ = row.becomeFirstResponder()
        #expect(row.fill?.cgColor == row.performWithTheme { Palette.selectionFill.cgColor })
        _ = row.resignFirstResponder()
        #expect(row.fill == nil)
    }

    @Test func theActiveRowStillShowsKeyFocus() {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var info = SidebarItemInfo(title: "Home", symbol: "house")
        info.isActive = true
        row.configure(info, style: .builtIn)
        let rest = row.fill?.cgColor
        _ = row.becomeFirstResponder()
        #expect(row.fill?.cgColor != rest)
        #expect(row.fill?.cgColor == row.performWithTheme { Palette.pressedFill.cgColor })
    }

    /// The update card's button and switch (Full Keyboard Access) ring in the theme's focus color.
    @Test func updateCardControlsRingInTheThemeColor() {
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let toggle = SidebarUpdateToggle(frame: NSRect(x: 0, y: 0, width: 120, height: 18))
        for view in [button, toggle] as [NSView] {
            #expect(view.focusRingType == .none)
            _ = view.becomeFirstResponder()
            view.updateLayer()
        }
        let ring = button.performWithTheme { Palette.focusRing.cgColor }
        #expect(button.layer?.borderColor == ring && (button.layer?.borderWidth ?? 0) > 0)
        // The switch's track is its first sublayer.
        #expect(toggle.layer?.sublayers?.first?.borderColor == ring)
    }

    /// As the system ring did, the tint shows only in the key window: a background window's
    /// sidebar keeps one selected-looking row, the active one.
    @Test func keyFocusHidesWhenTheWindowIsNotKey() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        row.configure(SidebarItemInfo(title: "Home", symbol: "house"), style: .builtIn)
        window.contentView?.addSubview(row)
        #expect(!window.isKeyWindow)
        _ = row.becomeFirstResponder()
        #expect(row.fill == nil)
    }
}
