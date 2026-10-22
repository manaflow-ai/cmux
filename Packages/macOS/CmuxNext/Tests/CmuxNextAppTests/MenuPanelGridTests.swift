import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// The menus cmux draws in its own panels sit on the same row grid as its themed menus (Leo
/// 2026-10-21: "idk if we genearlized the left alignment across all stuff yet"): the group
/// editors, the palette's actions menu, the page menus drawn past a window's edge and the
/// Extensions bubble. Each is built, laid out at a fixed width and measured: the frames of its
/// highlight, icon, title, separator and shortcut, in the surface's own coordinates, against
/// `MenuMetrics` (schemas/menu-metrics/menu-metrics.json).
@MainActor
struct MenuPanelGridTests {
    /// What a surface measured, in points from its leading edge (`trailing` from its trailing edge).
    struct Measured: CustomStringConvertible {
        var highlight: CGFloat
        var icon: CGFloat?
        var text: CGFloat
        var separator: CGFloat?
        var trailing: CGFloat?

        var description: String {
            func show(_ value: CGFloat?) -> String { value.map { "\($0)" } ?? "none" }
            return "highlight x \(highlight), icon x \(show(icon)), text x \(text), separator x \(show(separator)), shortcut trailing \(show(trailing))"
        }
    }

    private static func views<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { sub in ((sub as? View).map { [$0] } ?? []) + views(type, in: sub) }
    }

    private static func frame(_ view: NSView, in surface: NSView) -> NSRect { view.convert(view.bounds, to: surface) }

    /// `surface` at `width`, as tall as it asks, laid out.
    private static func layOut(_ surface: NSView, width: CGFloat) {
        surface.setFrameSize(NSSize(width: width, height: 600))
        surface.layoutSubtreeIfNeeded()
        let height = surface.fittingSize.height
        if height > 0 { surface.setFrameSize(NSSize(width: width, height: height)) }
        surface.layoutSubtreeIfNeeded()
    }

    private static func report(_ name: String, _ measured: Measured, icon: CGFloat?, text: CGFloat, separator: CGFloat?, trailing: CGFloat?) {
        print("menu-grid \(name): \(measured)")
        #expect(measured.highlight == MenuMetrics.highlightInset, "\(name): \(measured)")
        #expect(measured.icon == icon, "\(name): \(measured)")
        #expect(measured.text == text, "\(name): \(measured)")
        #expect(measured.separator == separator, "\(name): \(measured)")
        #expect(measured.trailing == trailing, "\(name): \(measured)")
    }

    /// The sidebar group editor: its rows have icons, so titles start after the icon column; the
    /// name field's box on the highlight's edges and the first dot's color on the icon column.
    @Test func theSidebarGroupEditorIsOnTheGrid() throws {
        let panel = SidebarGroupEditorPanel()
        let group = SidebarGroup(id: GroupID("grid-editor"), name: "web", color: .blue, workspaces: [])
        panel.configure(group, items: [
            [SidebarGroupEditorItem(id: "new", title: "New Workspace in Group", icon: .workspaceNew, shortcut: "⌘N")],
            [SidebarGroupEditorItem(id: "ungroup", title: "Ungroup", icon: .groupUngroup)],
        ])
        let surface = try #require(panel.glass)
        Self.layOut(surface, width: SidebarGroupEditorPanel.width)
        let row = try #require(Self.views(SidebarGroupEditorRow.self, in: surface).first { $0.item.id == "new" })
        let separator = try #require(Self.views(HairlineView.self, in: surface).first)
        let measured = Measured(highlight: Self.frame(row, in: surface).minX, icon: Self.frame(row.icon, in: surface).minX,
                                text: Self.frame(row.label, in: surface).minX, separator: Self.frame(separator, in: surface).minX,
                                trailing: surface.bounds.maxX - Self.frame(row.shortcut, in: surface).maxX)
        Self.report("sidebar group editor", measured, icon: MenuMetrics.iconX, text: MenuMetrics.textX(iconColumn: true),
                    separator: MenuMetrics.separatorInset, trailing: MenuMetrics.trailing)
        #expect(surface.bounds.maxX - Self.frame(separator, in: surface).maxX == MenuMetrics.separatorInset)
        let field = Self.frame(panel.field, in: surface)
        #expect(field.minX == MenuMetrics.highlightInset && surface.bounds.maxX - field.maxX == MenuMetrics.highlightInset, "the name field at \(field)")
        let dot = try #require(panel.swatches.first)
        let color = Self.frame(dot, in: surface).minX + SidebarGroupSwatchView.ringRoom
        #expect(color == MenuMetrics.iconX, "the first dot's color at \(color)")
    }

    /// The tab group editor: no row has an icon, so titles start on the icon column.
    @Test func theTabGroupEditorIsOnTheGrid() throws {
        let panel = TabGroupEditorPanel()
        panel.configure(TabGroupItem(id: TabGroupID("grid-tabs"), name: "web", colorToken: .blue))
        let surface = try #require(panel.glass)
        Self.layOut(surface, width: 260)
        let row = try #require(Self.views(TabGroupEditorRow.self, in: surface).first)
        let separator = try #require(Self.views(HairlineView.self, in: surface).first)
        let measured = Measured(highlight: Self.frame(row, in: surface).minX, icon: nil, text: Self.frame(row.label, in: surface).minX,
                                separator: Self.frame(separator, in: surface).minX, trailing: nil)
        Self.report("tab group editor", measured, icon: nil, text: MenuMetrics.textX(iconColumn: false),
                    separator: MenuMetrics.separatorInset, trailing: nil)
        let field = Self.frame(panel.field, in: surface)
        #expect(field.minX == MenuMetrics.highlightInset, "the name field at \(field)")
        let dot = try #require(Self.views(TabGroupSwatchView.self, in: surface).min { $0.frame.minX < $1.frame.minX })
        let color = Self.frame(dot, in: surface).minX + TabGroupSwatchView.ringRoom
        #expect(color == MenuMetrics.iconX, "the first swatch's color at \(color)")
    }

    /// The palette's Cmd-K actions menu: icons, the first row's ↩ on the trailing column, and its
    /// separator inset as a menu's (it ran edge to edge).
    @Test func thePaletteActionsMenuIsOnTheGrid() throws {
        let commands = [PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}),
                        PaletteCommand(id: "copy", title: "Copy Link", symbol: "link", effect: .perform {})]
        let state = PaletteActionsMenuState(itemID: "item", itemTitle: "cmux", commands: commands)
        let menu = PaletteActionsMenuView(frame: NSRect(x: 0, y: 0, width: PaletteLayout.actionsMenuWidth,
                                                        height: PaletteActionsMenuView.height(for: state)))
        menu.update(state, alternateID: nil)
        menu.layoutSubtreeIfNeeded()
        let row = try #require(Self.views(PaletteMenuRow.self, in: menu).first)
        row.layoutSubtreeIfNeeded()
        let measured = Measured(highlight: Self.frame(row, in: menu).minX, icon: Self.frame(row.icon, in: menu).minX,
                                text: Self.frame(row.label, in: menu).minX, separator: Self.frame(menu.separator, in: menu).minX,
                                trailing: menu.bounds.maxX - Self.frame(row.keys, in: menu).maxX)
        Self.report("palette actions menu", measured, icon: MenuMetrics.iconX, text: MenuMetrics.textX(iconColumn: true),
                    separator: MenuMetrics.separatorInset, trailing: MenuMetrics.trailing)
    }

    /// A page's menu drawn past its window's edge: a check column only when a row is checked.
    @Test(arguments: [true, false])
    func aPageMenuDrawnNativelyIsOnTheGrid(checked: Bool) throws {
        let rows = WebPopupRows(onPick: { _ in }, onHover: { _ in })
        rows.setFrameSize(NSSize(width: 240, height: 0))
        rows.update([WebPopupHost.Item(id: "a", label: "Copy", shortcut: "⌘C", checked: checked, disabled: false, separator: false),
                     WebPopupHost.Item(id: "-", label: "", shortcut: nil, checked: false, disabled: false, separator: true),
                     WebPopupHost.Item(id: "b", label: "Paste", shortcut: nil, checked: false, disabled: false, separator: false)],
                    highlighted: "a")
        let row = try #require(Self.views(PopupRowView.self, in: rows).first)
        let separator = try #require(Self.views(WebPopupSeparator.self, in: rows).first)
        let check = try #require(row.leadingView)
        let trailing = try #require(row.trailingView)
        let measured = Measured(highlight: Self.frame(row, in: rows).minX + row.rowLayout.fillInset.width,
                                icon: checked ? Self.frame(check, in: rows).minX : nil, text: Self.frame(row.titleLabel, in: rows).minX,
                                separator: separator.frame.minX + separator.line.minX, trailing: rows.bounds.maxX - Self.frame(trailing, in: rows).maxX)
        Self.report(checked ? "page menu (checked)" : "page menu", measured, icon: checked ? MenuMetrics.stateX : nil,
                    text: MenuMetrics.textX(iconColumn: false, stateColumn: checked), separator: MenuMetrics.separatorInset,
                    trailing: MenuMetrics.trailing)
    }

    /// The Extensions bubble: rows and buttons at the highlight inset and radius, an extension's
    /// icon on the icon column and its last button's glyph on the trailing column. Its 20-point
    /// icons are wider than the menus' icon column, so its titles keep their own column.
    @Test func theExtensionsBubbleIsOnTheGrid() throws {
        let view = ExtensionsMenuView()
        view.update([ExtensionsMenuView.Entry(info: BrowserExtensionInfo(id: "grid", name: "Grid", hasAction: true), icon: NSImage(),
                                              access: .allSites, canPin: true, hasSidePanel: false, tooltip: nil)], site: "example.com")
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.row(for: "grid"))
        row.layoutSubtreeIfNeeded()
        row.primary.layoutSubtreeIfNeeded()
        row.moreButton.layoutSubtreeIfNeeded()
        let measured = Measured(highlight: Self.frame(row, in: view).minX, icon: Self.frame(row.primary.imageView, in: view).minX,
                                text: Self.frame(row.primary.titleLabel, in: view).minX, separator: nil,
                                trailing: view.bounds.maxX - Self.frame(row.moreButton.imageView, in: view).maxX)
        let style = ExtensionsMenuStyle.standard
        Self.report("extensions bubble", measured, icon: MenuMetrics.iconX,
                    text: MenuMetrics.iconX - (style.extensionIconBox - style.extensionIcon) / 2 + style.extensionIconBox + style.imageLabelSpacing,
                    separator: nil, trailing: MenuMetrics.trailing)
        #expect(style.highlightRadius == MenuMetrics.highlightRadius)
        #expect(Self.frame(view.manageButton, in: view).minX == MenuMetrics.highlightInset)
    }
}
