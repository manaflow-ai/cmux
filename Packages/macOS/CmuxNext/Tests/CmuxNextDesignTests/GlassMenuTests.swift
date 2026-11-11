import AppKit
@testable import CmuxNextDesign
import Testing

/// The account menu on cmux's own glass (Leo, 2026-11-11: "Well, that's the whole point, right? Like
/// that's what we wanted to do anyways. have better design (systems too)"): ``GlassMenu`` draws an
/// `NSMenu`'s visible rows, on the menu glass with the one veil.
@MainActor @Suite struct GlassMenuTests {
    @Test func rowsSkipHiddenAndCustomViewItemsAndCollapseSeparators() {
        let menu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        let hidden = menu.addItem(withTitle: "Hidden", action: nil, keyEquivalent: "")
        hidden.isHidden = true
        menu.addItem(.separator())
        menu.addItem(.separator())
        let custom = menu.addItem(withTitle: "Header", action: nil, keyEquivalent: "")
        custom.view = NSView()
        menu.addItem(withTitle: "Sign Out", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let rows = GlassMenuRow.rows(of: menu)
        #expect(rows.map { $0.item?.title ?? "—" } == ["Settings…", "—", "Sign Out"])
    }

    @Test func shortcutsReadAsTheMenuDrawsThem() {
        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        #expect(GlassMenuRow.shortcut(settings) == "⌘,")
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "F")
        find.keyEquivalentModifierMask = [.command]
        #expect(GlassMenuRow.shortcut(find) == "⇧⌘F")
        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        #expect(GlassMenuRow.shortcut(none) == nil)
    }

    @Test func theMenuSurfaceIsTheMenuLevelWithTheVeil() {
        let surface = Glass.makeMenuPanel(content: NSView())
        #expect(surface.tintLevel == .menu)
        #expect(surface.cornerRadius == GlassMenuMaterial.cornerRadius)
        #expect(surface.contentView.subviews.first is GlassMenuVeilView)
        #expect(GlassMenuMaterial.veil == 0.4)
    }

    @Test func rowsSitOnTheMenuGridAndFitTheirWidth() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sign Out", action: nil, keyEquivalent: "")
        let list = GlassMenuListView()
        list.load(GlassMenuRow.rows(of: menu))
        let size = list.fittingMenuSize()
        #expect(size.width >= GlassMenuListView.minWidth)
        #expect(size.height == MenuMetrics.highlightInset * 2 + GlassMenuMaterial.rowHeight * 2 + GlassMenuListView.separatorHeight)
    }
}
