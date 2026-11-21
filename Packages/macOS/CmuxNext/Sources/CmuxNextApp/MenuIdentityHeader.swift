import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The top of the workspace, group and space right-click menus, as in Chrome's tab-group menu (Leo 2026-10-20: "why are
/// the right-click things not like Chrome?"): the name in a field you can edit in place, then the colors as one row of
/// swatches with the current one ringed, in place of the Rename… row and the color submenu; a separator follows.
/// The field renames when Return is pressed or the menu closes with a changed name (Chrome keeps what you typed too),
/// through the rename action with a `name` argument. A swatch runs its color choice as the color row did. The row that
/// removes the color leaves the menu for the first swatch, No Color (Lawrence 2026-10-22).
@MainActor
enum MenuIdentityHeader {
    /// The rows that remove a color: each becomes the No Color swatch.
    static let clearActions: Set<ActionID> = ["palette.resetWorkspaceColor", "workspaceGroup.clearColor", "space.clearColor"]

    /// Puts the header at the top of `menu`. `rename` is the menu's rename action: given a `name`, its
    /// row leaves the menu for the field; with no `name` (a multi-row selection) the row stays and the
    /// header shows only the swatches. The color choices are the rows of the submenu whose rows each
    /// set a group color; for the group menu `current` names the ringed one, for the workspace menu
    /// the row whose state is on. `noColor`: the group has no color (`GroupTint.none`), so No Color
    /// is ringed; a workspace menu rings it when no color row is on. A menu with neither is left as it is.
    static func install(in menu: NSMenu, registry: ActionRegistry, target: ActionTargetRef, name: String?, rename: ActionID,
                        current: GroupColor? = nil, noColor: Bool = false) {
        // A rename that can't run on this target (no daemon support yet) keeps its disabled row, not a dead field.
        // The field always sends a name, so ask whether a rename with this name can run: a pinned
        // workspace's tile has no list row for the inline rename, yet renames by name.
        let named = name.map { ["name": ActionValue.string($0)] } ?? [:]
        let renames = ActionTargetReasons.canPerform(rename, invocation: ActionInvocation(target: target, arguments: named), in: registry)
        let renameIndex = name == nil || !renames ? nil : menu.items.firstIndex { ActionRegistry.menuRun(of: $0)?.id == rename }
        let colorIndex = menu.items.firstIndex { item in
            (item.submenu?.items.filter { color(of: $0) != nil }.count ?? 0) >= 2
        }
        guard renameIndex != nil || colorIndex != nil else { return }
        let colorMenu = colorIndex.flatMap { menu.items[$0].submenu }, colorTitle = colorIndex.map { menu.items[$0].title }, choices = colorMenu?.items.filter { color(of: $0) != nil } ?? []
        // The clear row, wherever the menu keeps it (the color submenu, or a folder), only beside swatches.
        let clear = colorMenu.map { takeClearRow(from: $0) ?? takeClearRow(from: menu) } ?? nil
        // Its rows that set no color (a space's theme rows) take the color row's place (Leo 2026-11-11: "this colour selection for spaces is wack").
        let colorRun = choices.first.flatMap { ActionRegistry.menuRun(of: $0)?.id } // a More… row runs the color action and goes with it
        let others = colorMenu?.items.filter { color(of: $0) == nil && !$0.isSeparatorItem && ActionRegistry.menuRun(of: $0)?.id != colorRun } ?? []; others.forEach { colorMenu?.removeItem($0) }
        let renameItem = renameIndex.map { menu.items[$0] }
        if let colorIndex { menu.removeItem(at: colorIndex); others.reversed().forEach { menu.insertItem($0, at: colorIndex) } }
        if let renameItem { menu.removeItem(renameItem) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }

        let field = renameIndex.map { _ in
            MenuNameField(name: name ?? "", placeholder: placeholder(for: rename, registry: registry)) { newName in
                // With a name the rename only sends it; it opens no field of its own.
                registry.perform(rename, invocation: ActionInvocation(target: target, arguments: ["name": .string(newName)]))
            }
        }
        // The group and space menus name their color (none for a custom `#RRGGBB` one); the workspace rows carry it as their state.
        let ringed = rename != "renameWorkspace" ? current : choices.first { $0.state == .on }.flatMap(color(of:))
        let clearIsCurrent = rename != "renameWorkspace" ? noColor : ringed == nil && !choices.contains { $0.state == .mixed }
        let strip = choices.isEmpty ? nil : MenuSwatchStrip(title: colorTitle ?? "", choices: choices, colors: choices.map(color(of:)), current: ringed, clear: clear, clearIsCurrent: clearIsCurrent)
        let header = NSMenuItem()
        header.view = MenuIdentityHeaderView(field: field, strip: strip)
        if let colorTitle { header.setAccessibilityLabel(colorTitle) }
        menu.insertItem(header, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    }

    /// Removes the clear row (`clearActions`) from `menu` or any of its submenus and returns it; an
    /// emptied folder and a separator left at a menu's edge go with it.
    private static func takeClearRow(from menu: NSMenu) -> NSMenuItem? {
        for (index, item) in menu.items.enumerated() {
            if let run = ActionRegistry.menuRun(of: item), clearActions.contains(run.id) {
                menu.removeItem(at: index)
                trimSeparators(menu)
                return item
            }
            if let submenu = item.submenu, let found = takeClearRow(from: submenu) {
                if !submenu.items.contains(where: { !$0.isSeparatorItem }) { menu.removeItem(item) }
                return found
            }
        }
        return nil
    }

    private static func trimSeparators(_ menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var index = 1
        while index < menu.items.count {
            if menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) } else { index += 1 }
        }
    }

    /// The group color a menu row sets: a choices row's `color` argument (Set Workspace Color) or a
    /// group's per-color action (`workspaceGroup.color.<color>`).
    static func color(of item: NSMenuItem) -> GroupColor? {
        guard let run = ActionRegistry.menuRun(of: item) else { return nil }
        if let raw = run.arguments["color"]?.stringValue { return GroupColor(rawValue: raw) }
        guard let prefix = ["workspaceGroup.color.", "space.color."].first(where: run.id.rawValue.hasPrefix) else { return nil }
        return GroupColor(rawValue: String(run.id.rawValue.dropFirst(prefix.count)))
    }

    /// The field's placeholder: the rename action's `name` argument ("Name"), else its title.
    private static func placeholder(for rename: ActionID, registry: ActionRegistry) -> String {
        registry.descriptor(for: rename)?.arguments.first { $0.name == "name" }?.title ?? registry.title(for: rename) ?? ""
    }
}
