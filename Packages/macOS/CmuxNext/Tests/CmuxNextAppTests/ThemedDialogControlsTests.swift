import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Dialogs paint the theme, never macOS's blue (cx-wqn5): New Message's Return button and its
/// selected person row take the theme's selection fill, as the sidebar and palette rows do,
/// not the system accent, even while the sheet's window is key.
@MainActor
struct ThemedDialogControlsTests {
    @Test func newMessageDrawsTheThemeNotTheAccent() throws {
        let sheet = HomeComposeSheet(contacts: [HomeContact(id: ParticipantID("ada"), name: "Ada", source: .team)])
        _ = sheet.view
        sheet.table.reloadData()
        #expect(sheet.table.numberOfRows > 0)

        // The Return button takes a theme fill, not the accent a default button draws in.
        let bezel = try #require(sheet.primaryButton.bezelColor)
        #expect(Self.isNeutral(sheet.view.performWithTheme { bezel.usingColorSpace(.sRGB) }))

        // A selected row in a key window (emphasized) still draws the theme's gray, not blue.
        sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let row = try #require(sheet.table.rowView(atRow: 0, makeIfNecessary: true))
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
