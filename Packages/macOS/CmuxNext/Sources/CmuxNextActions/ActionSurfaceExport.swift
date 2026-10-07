import Foundation

/// The catalog's surface declarations as JSON, checked in at
/// `plans/cmux-next/action-surfaces.json` so the Rust CLI and MCP parity
/// tests read the same list the app serves in `action.list` without a
/// running app. `ActionSurfaceParityTests.exportIsFresh` keeps it current.
public nonisolated enum ActionSurfaceExport {
    /// One action's wire form (also `action.list`'s `surfaces` member).
    public static func object(_ descriptor: ActionDescriptor) -> [String: Any] {
        let plan = descriptor.surfacePlan
        let contexts = plan.contextMenus.map(\.context.rawValue)
        var unique: [String] = []
        for context in contexts where !unique.contains(context) { unique.append(context) }
        return [
            "id": descriptor.id.rawValue,
            "cli_name": descriptor.cliName,
            "palette": plan.palette.wireValue,
            "cli": plan.cli?.wireValue ?? "undeclared",
            "context_menu": plan.contextMenu?.wireValue ?? "undeclared",
            "context_menus": unique,
            "mcp": plan.mcp?.wireValue ?? "undeclared",
        ]
    }

    /// One action's row in the checked-in export: the wire form plus what
    /// other clients need to show it without the app (title and its
    /// localization key, default shortcut and chord).
    public static func catalogObject(_ descriptor: ActionDescriptor, titles: ActionTitleCatalog) -> [String: Any] {
        var row = object(descriptor)
        let entry = titles.entry(for: descriptor)
        row["title"] = entry?.english ?? descriptor.title
        row["title_key"] = entry.map { $0.key as Any } ?? NSNull()
        row["title_table"] = entry.map { $0.table as Any } ?? NSNull()
        var shortcut: Any = NSNull()
        if let defaultShortcut = descriptor.defaultShortcut {
            var wire = wireShortcut(defaultShortcut)
            if descriptor.shortcutFamily == .digits { wire["family"] = "digits" }
            shortcut = wire
        }
        row["default_shortcut"] = shortcut
        let category = descriptor.category
        row["palette_section"] = [
            "id": category.paletteSectionID,
            "title_key": category.titleKey,
            "title_table": category.titleTable,
            "title": titles.entry(key: category.titleKey, table: category.titleTable)?.english ?? category.title,
            "order": category.paletteSectionOrder,
        ] as [String: Any]
        row["default_chord"] = descriptor.defaultChord.map { [wireShortcut($0.first), wireShortcut($0.second)] as Any } ?? NSNull()
        row["default_aliases"] = defaultAliases(for: descriptor.id)
        return row
    }

    /// The binding table's default entries for `id` beyond its catalog key
    /// (`KeyBindingDefaults`: browser tab keys, Ctrl-Cmd arrows for pane
    /// resize, Ctrl-Cmd H/J/K/L for pane focus, list navigation, the palette keys): each entry's keys and its `when` clause
    /// (text, or null), in table order, each key sequence once.
    public static func defaultAliases(for id: ActionID) -> [[String: Any]] {
        let entries = KeyBindingDefaults.tabSwitching + KeyBindingDefaults.actionAliases + KeyBindingDefaults.listNavigation
            + KeyBindingDefaults.homeNavigation
            + KeyBindingDefaults.paletteKeys
        var seen: [[Shortcut]] = []
        var aliases: [[String: Any]] = []
        for entry in entries where entry.command == id && !seen.contains(entry.keys) {
            seen.append(entry.keys)
            aliases.append(["keys": entry.keys.map(wireShortcut), "when": entry.when.map { $0.text as Any } ?? NSNull()])
        }
        return aliases
    }

    /// A shortcut in platform-neutral form: the key as typed (lowercased)
    /// and its modifiers in the order ctrl, opt, shift, cmd.
    public static func wireShortcut(_ shortcut: Shortcut) -> [String: Any] {
        var modifiers: [String] = []
        if shortcut.modifiers.contains(.control) { modifiers.append("ctrl") }
        if shortcut.modifiers.contains(.option) { modifiers.append("opt") }
        if shortcut.modifiers.contains(.shift) { modifiers.append("shift") }
        if shortcut.modifiers.contains(.command) { modifiers.append("cmd") }
        return ["key": shortcut.key, "modifiers": modifiers]
    }

    /// The whole catalog, keys sorted, one stable text.
    public static func json(_ descriptors: [ActionDescriptor], titles: ActionTitleCatalog = ActionTitleCatalog()) -> String {
        let actions = descriptors.map { catalogObject($0, titles: titles) }
        let root: [String: Any] = [
            "version": 1, "actions": actions,
            "context_menus": ContextMenuCatalog(descriptors: descriptors).exportObject(descriptors: descriptors, titles: titles),
            "context_menu_rules": ContextMenuCatalog.exportRenderRules,
            "context_menus_not_exported": ContextMenuCatalog.exportHandBuiltMenus,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text + "\n"
    }
}
