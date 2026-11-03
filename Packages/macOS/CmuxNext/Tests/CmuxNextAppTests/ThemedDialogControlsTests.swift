import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxTheme
import Testing

/// Dialogs paint the theme, never macOS's blue (cx-wqn5): New Message's highlighted suggestion
/// (the page's To: list, no sheet since 2026-10-19) takes the theme's selection fill, as the
/// sidebar and palette rows do, not the system accent, even while the window is key.
@MainActor
struct ThemedDialogControlsTests {
    @Test func newMessageDrawsTheThemeNotTheAccent() throws {
        let list = HomeRecipientSuggestionsView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        // The list draws in its own neutral (no accent) theme: the app theme is process-wide, and a
        // suite that applies an accent theme to it (the sidebar galleries' Soft Blue) left this
        // check reading that theme's blue selection, which is the theme's fill, not the system's.
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("neutral"), input: .ghosttyDefault, animated: false)
        scope.root(list)
        list.show([.contact(HomeContact(id: ParticipantID("ada"), name: "Ada", source: .team))])
        #expect(list.table.numberOfRows == 1)
        #expect(list.highlighted == 0)

        // A highlighted row in a key window (emphasized) still draws the theme's gray, not blue.
        let row = try #require(list.table.rowView(atRow: 0, makeIfNecessary: true))
        row.frame = NSRect(x: 0, y: 0, width: 380, height: 28)
        row.isSelected = true
        row.isEmphasized = true
        let fill = try #require(Self.pixel(row, x: 370, y: 14))
        #expect(fill.alphaComponent > 0)
        #expect(Self.isNeutral(fill))
    }

    /// Low chroma: a theme gray, not the system accent's blue.
    private static func isNeutral(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        return channels.max()! - channels.min()! < 0.08
    }

    private static func pixel(_ view: NSView, x: Int, y: Int) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.colorAt(x: x * rep.pixelsWide / Int(view.bounds.width), y: y * rep.pixelsHigh / Int(view.bounds.height))
    }
}
