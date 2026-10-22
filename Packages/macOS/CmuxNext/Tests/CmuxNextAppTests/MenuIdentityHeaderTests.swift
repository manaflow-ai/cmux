import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The workspace and group menus open as Chrome's tab-group menu does (Leo 2026-10-20): the name
/// in an editable field and the colors as swatches, in place of Rename… and the color submenu.
@MainActor
struct MenuIdentityHeaderTests {
    private let target = ActionTargetRef(kind: .workspace, id: "ws")

    /// A registry whose rename records the name it was given, and a workspace menu built from it.
    private func workspaceMenu() -> (ActionRegistry, NSMenu, Box) {
        let registry = ActionRegistry.standard()
        let renamed = Box()
        registry.bind("renameWorkspace", invoke: { renamed.names.append($0["name"]?.stringValue ?? "") })
        registry.bind("palette.workspaceColor", invoke: { _ in })
        registry.bind("moveWorkspaceToGroup", invoke: { _ in })
        return (registry, registry.makeContextMenu(for: .workspaceRow, target: target), renamed)
    }

    @Test func theNameFieldAndSwatchesReplaceRenameAndTheColorRow() throws {
        let (registry, menu, _) = workspaceMenu()
        let colors = try #require(menu.items.first { $0.submenu?.items.contains { ActionRegistry.menuRun(of: $0)?.id == "palette.workspaceColor" } == true })
        let colorCount = colors.submenu?.items.filter { MenuIdentityHeader.color(of: $0) != nil }.count ?? 0
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "api", rename: "renameWorkspace")

        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView, "the menu opens with the header")
        #expect(menu.items[1].isSeparatorItem)
        #expect(header.field?.stringValue == "api")
        #expect(header.strip != nil && colorCount >= 2)
        let ids = menu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
        #expect(!ids.contains("renameWorkspace"), "Rename… is the field now")
        #expect(!menu.items.contains { $0.submenu?.items.contains { ActionRegistry.menuRun(of: $0)?.id == "palette.workspaceColor" } == true })
    }

    @Test func aChangedNameRenamesOnceAndAnUnchangedOneDoesNot() throws {
        let (registry, menu, renamed) = workspaceMenu()
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "api", rename: "renameWorkspace")
        let field = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.field)

        field.commit()
        #expect(renamed.names.isEmpty, "closing with the same name renames nothing")

        field.reset()
        field.stringValue = "  api server "
        field.commit()
        field.commit()
        #expect(renamed.names == ["api server"])

        field.reset()
        field.stringValue = "   "
        field.commit()
        #expect(renamed.names == ["api server"], "a blank name is not a rename")
    }

    /// Escape closes the menu before the field sees the key (live dogfood, 2026-10-20): the menu
    /// closing on an Escape press keeps the old name, as Escape on any menu cancels.
    @Test func closingTheMenuWithEscapeRenamesNothing() throws {
        let (registry, menu, renamed) = workspaceMenu()
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "api", rename: "renameWorkspace")
        let field = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.field)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))

        field.reset()
        field.stringValue = "ch"
        field.menuClosed(by: escape)
        #expect(renamed.names.isEmpty, "Escape keeps the old name")

        field.reset()
        field.stringValue = "de"
        field.menuClosed(by: nil)
        #expect(renamed.names == ["de"], "a click outside keeps what was typed")
    }

    /// A multi-row selection renames no one row: the header is the swatches alone.
    @Test func aSelectionGetsSwatchesWithoutAField() throws {
        let (registry, menu, _) = workspaceMenu()
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: nil, rename: "renameWorkspace")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        #expect(header.field == nil && header.strip != nil)
    }

    /// A rename that can't run on the target keeps its (disabled) row and gets no dead field.
    @Test func aRenameThatCannotRunKeepsItsRowAndShowsNoField() throws {
        let registry = ActionRegistry.standard()
        registry.bind("renameWorkspace", isEnabled: { false }, invoke: { _ in })
        registry.bind("palette.workspaceColor", invoke: { _ in })
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "api", rename: "renameWorkspace")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        #expect(header.field == nil)
        #expect(menu.items.contains { ActionRegistry.menuRun(of: $0)?.id == "renameWorkspace" })
    }

    /// u9783 (2026-10-21): "right click workspace, add color, i can no longer remove the color". The
    /// header's swatches (c7ebff44c93) took the color row's place but kept only the colors, and
    /// Reset Workspace Color sat in More. The color row ends with Remove Color, checked while the
    /// workspace has no color, and the header offers it as its first swatch.
    private func colorMenu(current: String?, resets: Box) -> (ActionRegistry, NSMenu) {
        let registry = ActionRegistry.standard()
        registry.bind("renameWorkspace", invoke: { _ in })
        registry.bind("palette.workspaceColor", invoke: { _ in })
        registry.bind("palette.resetWorkspaceColor", invoke: { _ in resets.names.append("reset") })
        ActionTargetTitles.setChoiceState("palette.workspaceColor", in: registry) { _ in current }
        return (registry, registry.makeContextMenu(for: .workspaceRow, target: target))
    }

    private func colorRows(_ menu: NSMenu) throws -> [NSMenuItem] {
        let row = try #require(menu.items.first { $0.submenu?.items.contains { ActionRegistry.menuRun(of: $0)?.id == "palette.workspaceColor" } == true })
        return row.submenu?.items ?? []
    }

    @Test func theColorRowEndsWithRemoveColorCheckedWhileTheWorkspaceHasNone() throws {
        let (_, unset) = colorMenu(current: nil, resets: Box())
        let rows = try colorRows(unset)
        let remove = try #require(rows.first { ActionRegistry.menuRun(of: $0)?.id == "palette.resetWorkspaceColor" }, "the color row can remove the color")
        #expect(remove.state == .on, "no color: Remove Color is checked")
        #expect(!rows.contains { MenuIdentityHeader.color(of: $0) != nil && $0.state == .on })

        let (_, blue) = colorMenu(current: "blue", resets: Box())
        let blueRows = try colorRows(blue)
        #expect(blueRows.first { MenuIdentityHeader.color(of: $0) == .blue }?.state == .on, "the workspace's color is checked")
        #expect(blueRows.first { ActionRegistry.menuRun(of: $0)?.id == "palette.resetWorkspaceColor" }?.state == .off)

        // One Remove Color: More holds no second Reset Workspace Color row.
        func count(_ menu: NSMenu) -> Int {
            menu.items.reduce(0) { $0 + (ActionRegistry.menuRun(of: $1)?.id == "palette.resetWorkspaceColor" ? 1 : 0) + ($1.submenu.map(count) ?? 0) }
        }
        #expect(count(blue) == 1)
    }

    @Test(arguments: [true, false])
    func theSwatchesOfferNoColorAndItRemovesTheColor(oneRow: Bool) throws {
        let resets = Box()
        let (registry, menu) = colorMenu(current: nil, resets: resets)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: oneRow ? "api" : nil, rename: "renameWorkspace")
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        let actions = strip.accessibilityCustomActions() ?? []
        let removeTitle = try #require(try colorRows(colorMenu(current: nil, resets: Box()).1)
            .first { ActionRegistry.menuRun(of: $0)?.id == "palette.resetWorkspaceColor" }?.title)
        let remove = try #require(actions.first { $0.name == removeTitle }, "the swatches offer \(removeTitle)")
        #expect(strip.accessibilityValue() as? String == removeTitle, "no color is the current choice")
        _ = remove.handler?()
        #expect(resets.names == ["reset"], "the no-color swatch removes the color")
    }

    /// The group menu's colors are per-color actions (`workspaceGroup.color.<color>`).
    @Test func theGroupMenuReadsItsPerColorRows() {
        let registry = ActionRegistry.standard()
        let menu = registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: "g"),
                                            entries: [.submenu("workspaceGroup.setColor", [.action("workspaceGroup.color.blue"), .action("workspaceGroup.color.red")])])
        let colors = menu.items.first?.submenu?.items.compactMap(MenuIdentityHeader.color(of:)) ?? []
        #expect(colors == [.blue, .red])
    }
}

@MainActor private final class Box {
    var names: [String] = []
}
