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

    /// Review F1 of #41538: an empty menu, or one of separators only, has no rows (it never
    /// removes from an empty list).
    @Test func anEmptyOrSeparatorOnlyMenuHasNoRows() {
        #expect(GlassMenuRow.rows(of: NSMenu()).isEmpty)
        let separators = NSMenu()
        separators.addItem(.separator())
        separators.addItem(.separator())
        #expect(GlassMenuRow.rows(of: separators).isEmpty)
    }

    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    /// Review F2 of #41538: a shortcut pressed while the menu is open finds its row, as an open
    /// NSMenu runs it (⌘, opens Settings), in a submenu too; a disabled row or other modifiers do not.
    @Test func aShortcutFindsItsRowWhileTheMenuIsOpen() throws {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(NSText.copy(_:)), keyEquivalent: ",")
        let help = menu.addItem(withTitle: "Help", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let shortcuts = sub.addItem(withTitle: "Keyboard Shortcuts", action: #selector(NSText.copy(_:)), keyEquivalent: "/")
        help.submenu = sub
        let off = menu.addItem(withTitle: "Off", action: #selector(NSText.copy(_:)), keyEquivalent: "k")
        off.isEnabled = false
        #expect(GlassMenuRow.item(matching: try Self.key(",", .command), in: menu) === settings)
        #expect(GlassMenuRow.item(matching: try Self.key("/", .command), in: menu) === shortcuts)
        #expect(GlassMenuRow.item(matching: try Self.key(",", [.command, .option]), in: menu) == nil)
        #expect(GlassMenuRow.item(matching: try Self.key("k", .command), in: menu) == nil)

        let list = GlassMenuListView()
        var pressed: NSEvent?
        list.onKeyEquivalent = { event in
            pressed = event
            return GlassMenuRow.item(matching: event, in: menu) != nil
        }
        #expect(list.performKeyEquivalent(with: try Self.key(",", .command)))
        #expect(pressed?.charactersIgnoringModifiers == ",")
    }

    /// Review F3 of #41538: a mixed row draws the mixed mark, not nothing.
    @Test func aMixedRowDrawsTheMixedMark() throws {
        let menu = NSMenu()
        let mixed = menu.addItem(withTitle: "Some", action: nil, keyEquivalent: "")
        mixed.state = .mixed
        menu.addItem(withTitle: "Plain", action: nil, keyEquivalent: "")
        let list = GlassMenuListView()
        list.load(GlassMenuRow.rows(of: menu))
        let row = try #require(list.view(at: 0) as? PopupRowView)
        #expect(row.trailingView is ThemedImageView)
        #expect((list.view(at: 1) as? PopupRowView)?.trailingView == nil)
    }

    /// Review P1-F1 of #41538: a picked row runs after the menu closes even when nothing else holds
    /// the menu (the sidebar keeps its account menu weakly, and `NSMenuItem.menu` is weak), in a
    /// submenu too.
    @Test func aPickedRowRunsWhenNothingElseHoldsTheMenu() throws {
        let target = GlassMenuActionTarget()
        do {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let settings = menu.addItem(
                withTitle: "Settings…", action: #selector(GlassMenuActionTarget.run(_:)), keyEquivalent: ",")
            settings.target = target
            let glass = GlassMenu(menu: menu)
            #expect(glass.runKeyEquivalent(try Self.key(",", .command)))
        }
        do {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let more = menu.addItem(withTitle: "More", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let team = sub.addItem(
                withTitle: "Team", action: #selector(GlassMenuActionTarget.run(_:)), keyEquivalent: "t")
            team.target = target
            more.submenu = sub
            #expect(GlassMenu(menu: menu).runKeyEquivalent(try Self.key("t", .command)))
        }
        #expect(target.ran.isEmpty, "the row ran inline, before the menu closed")
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        #expect(target.ran == ["Settings…", "Team"])
    }
}

@MainActor final class GlassMenuActionTarget: NSObject {
    var ran: [String] = []
    @objc func run(_ sender: NSMenuItem) { ran.append(sender.title) }
}
