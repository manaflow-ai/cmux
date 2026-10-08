import AppKit
import Testing
@testable import CmuxNextActions

/// cx-k9go (Lawrence 2026-10-08, "allow right click clear icons in general
/// across app"): every object whose icon can be set offers "Set Icon…" and,
/// while it shows an icon, "Remove Icon" next to it in its own right-click
/// menu. Both rows run the shared catalog actions, so the palette, the menu
/// bar and the CLI keep the actions' full titles.
@MainActor @Suite struct IconContextMenuTests {
    /// (menu, target kind, set action, clear action, set row, remove row).
    static let menus: [(ActionMenuContext, ActionTargetKind, ActionID, ActionID, String, String)] = [
        (.workspaceRow, .workspace, "workspace.setIcon", "workspace.clearIcon", "Set Icon…", "Remove Icon"),
        (.workspaceGroup, .workspaceGroup, "workspaceGroup.setIcon", "workspaceGroup.clearIcon", "Set Icon…", "Remove Icon"),
        (.tab, .tab, "tab.setIcon", "tab.clearIcon", "Set Icon…", "Remove Icon"),
        (.screen, .screen, "screen.setIcon", "screen.clearIcon", "Set Icon…", "Remove Icon"),
        (.browserProfile, .browserProfile, "browserProfile.setIcon", "browserProfile.clearIcon", "Set Icon…", "Remove Icon"),
        (.profile, .profile, "space.setIcon", "space.clearIcon", "Change Space Icon…", "Remove Space Icon"),
    ]

    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for (context, _, _, _, _, _) in Self.menus {
            for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context)) {
                registry.bind(id, invoke: { _ in })
            }
        }
        return registry
    }

    /// Every row title of a menu and its submenus, in order.
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            if item.isSeparatorItem { return ["—"] }
            return [item.title] + (item.submenu.map(titles) ?? [])
        }
    }

    @Test func everyIconMenuOffersSetIconAndRemoveIconTogether() {
        let registry = registry()
        for (context, kind, _, _, set, remove) in Self.menus {
            let rows = titles(registry.makeContextMenu(for: context, target: ActionTargetRef(kind: kind, id: "x")))
            let index = rows.firstIndex(of: set)
            #expect(index != nil, "\(context) has no \(set): \(rows)")
            #expect(index.map { rows.indices.contains($0 + 1) && rows[$0 + 1] == remove } == true, "\(context): \(rows)")
            #expect(rows.filter { $0 == remove }.count == 1, "\(context) lists \(remove) once")
        }
    }

    @Test func removeIconIsLeftOutWhereThereIsNoIcon() {
        let registry = registry()
        for (context, kind, _, clear, set, remove) in Self.menus {
            ActionTargetVisibility.hide(clear, in: registry) { $0.target?.id == "plain" }
            let plain = titles(registry.makeContextMenu(for: context, target: ActionTargetRef(kind: kind, id: "plain")))
            let iconned = titles(registry.makeContextMenu(for: context, target: ActionTargetRef(kind: kind, id: "iconned")))
            #expect(plain.contains(set) && !plain.contains(remove), "\(context): \(plain)")
            #expect(iconned.contains(remove), "\(context): \(iconned)")
        }
    }

    /// The short rows are menu labels only: the palette and the CLI keep the
    /// titles that name the object.
    @Test func thePaletteKeepsTheFullTitles() throws {
        let registry = registry()
        for (_, _, setID, clearID, set, remove) in Self.menus {
            #expect(try #require(registry.title(for: setID)) != set)
            #expect(try #require(registry.title(for: clearID)) != remove)
        }
    }
}
