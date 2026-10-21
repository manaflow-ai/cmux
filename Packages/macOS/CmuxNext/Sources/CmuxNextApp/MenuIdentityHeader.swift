import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The top of the workspace and group right-click menus, as in Chrome's tab-group menu (Leo
/// 2026-10-20: "why are the right-click things not like Chrome?"): the name in a field you can
/// edit in place, then the colors as one row of swatches with the current one ringed. It takes the
/// place of the menu's Rename… row and its color submenu; a separator divides it from the rest.
///
/// The field renames when Return is pressed or the menu closes with a changed name (Chrome keeps
/// what you typed too), through the rename action with a `name` argument. A swatch runs its color
/// choice as the color row did.
@MainActor
enum MenuIdentityHeader {
    /// Puts the header at the top of `menu`. `rename` is the menu's rename action: given a `name`, its
    /// row leaves the menu for the field; with no `name` (a multi-row selection) the row stays and the
    /// header shows only the swatches. The color choices are the rows of the submenu whose rows each
    /// set a group color; for the group menu `current` names the ringed one, for the workspace menu
    /// the row whose state is on. A menu with neither is left as it is.
    static func install(in menu: NSMenu, registry: ActionRegistry, target: ActionTargetRef, name: String?, rename: ActionID,
                        current: GroupColor? = nil) {
        // A rename that can't run on this target (no daemon support yet) keeps its disabled row, not a dead field.
        let renames = ActionTargetReasons.canPerform(rename, invocation: ActionInvocation(target: target), in: registry)
        let renameIndex = name == nil || !renames ? nil : menu.items.firstIndex { ActionRegistry.menuRun(of: $0)?.id == rename }
        let colorIndex = menu.items.firstIndex { item in
            (item.submenu?.items.filter { color(of: $0) != nil }.count ?? 0) >= 2
        }
        guard renameIndex != nil || colorIndex != nil else { return }
        let choices = colorIndex.map { menu.items[$0].submenu?.items.filter { color(of: $0) != nil } ?? [] } ?? []
        let colorTitle = colorIndex.map { menu.items[$0].title }
        for index in [renameIndex, colorIndex].compactMap({ $0 }).sorted(by: >) { menu.removeItem(at: index) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }

        let field = renameIndex.map { _ in
            MenuNameField(name: name ?? "", placeholder: placeholder(for: rename, registry: registry)) { newName in
                // With a name the rename only sends it; it opens no field of its own.
                registry.perform(rename, invocation: ActionInvocation(target: target, arguments: ["name": .string(newName)]))
            }
        }
        // The group menu names its color (none for a custom `#RRGGBB` one); the workspace rows carry it as their state.
        let ringed = rename == "workspaceGroup.rename" ? current : choices.first { $0.state == .on }.flatMap(color(of:))
        let strip = choices.isEmpty ? nil : MenuSwatchStrip(title: colorTitle ?? "", choices: choices, colors: choices.map(color(of:)), current: ringed)
        let header = NSMenuItem()
        header.view = MenuIdentityHeaderView(field: field, strip: strip)
        if let colorTitle { header.setAccessibilityLabel(colorTitle) }
        menu.insertItem(header, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    }

    /// The group color a menu row sets: a choices row's `color` argument (Set Workspace Color) or a
    /// group's per-color action (`workspaceGroup.color.<color>`).
    static func color(of item: NSMenuItem) -> GroupColor? {
        guard let run = ActionRegistry.menuRun(of: item) else { return nil }
        if let raw = run.arguments["color"]?.stringValue { return GroupColor(rawValue: raw) }
        let prefix = "workspaceGroup.color."
        guard run.id.rawValue.hasPrefix(prefix) else { return nil }
        return GroupColor(rawValue: String(run.id.rawValue.dropFirst(prefix.count)))
    }

    /// The field's placeholder: the rename action's `name` argument ("Name"), else its title.
    private static func placeholder(for rename: ActionID, registry: ActionRegistry) -> String {
        registry.descriptor(for: rename)?.arguments.first { $0.name == "name" }?.title ?? registry.title(for: rename) ?? ""
    }
}
