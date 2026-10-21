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

    /// A multi-row selection renames no one row: the header is the swatches alone.
    @Test func aSelectionGetsSwatchesWithoutAField() throws {
        let (registry, menu, _) = workspaceMenu()
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: nil, rename: "renameWorkspace")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        #expect(header.field == nil && header.strip != nil)
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
