public import CmuxNextActions

/// The person's right-click menu arrangements, in cmux.json (Settings > Menus):
///
/// ```jsonc
/// "contextMenus": {
///   "showCustomizeItem": true,
///   "layouts": {
///     "workspaceRow": {
///       "items": ["renameWorkspace", "workspace.copyPath", "-",
///                 {"key": "group:a1", "title": "Mine", "items": ["home.messageAbout", {"key": "folder:move", "items": []}]},
///                 {"key": "folder:more", "items": ["palette.markWorkspaceUnread"]}, "-", "closeWorkspace"],
///       "hidden": ["workspace.duplicate"]
///     }
///   }
/// }
/// ```
///
/// A menu without a layout is drawn as the app generates it (``ContextMenuLayout``). An unknown
/// menu or a malformed layout is dropped with a diagnostic; unknown row keys are dropped when the
/// layout is applied, so a row the app retired never breaks the menu.
public nonisolated struct ContextMenusSetting: Sendable, Hashable {
    public static let configPath = ["contextMenus"]
    public static let layoutsPath = configPath + ["layouts"]
    public static let showCustomizeItemPath = configPath + ["showCustomizeItem"]

    public var layouts: [ActionMenuContext: ContextMenuLayout] = [:]
    public var showsCustomizeItem = true

    public init(layouts: [ActionMenuContext: ContextMenuLayout] = [:], showsCustomizeItem: Bool = true) {
        self.layouts = layouts
        self.showsCustomizeItem = showsCustomizeItem
    }

    /// `contextMenus.showCustomizeItem` as a schema row, so the palette, `cmux settings` and MCP
    /// change it as they change every setting. Settings > Menus draws it as its own switch
    /// (ContextMenusCard), so the page keeps the row off its lists.
    static var showCustomizeItemDescriptor: SettingDescriptor {
        var row = SettingDescriptor(
            showCustomizeItemPath, section: .general, group: SettingsText.keyed("settings.category.menus", "Menus"),
            title: SettingsText.keyed("settings.contextMenus.showCustomizeItem", "Show Customize Menu…"),
            help: SettingsText.keyed("settings.contextMenus.showCustomizeItem.help", "Adds Customize Menu… to the end of every right-click menu."),
            kind: .toggle, default: .bool(true),
            keywords: ["context menu", "right click", "customize", "menu"]
        )
        row.page = .hidden("Settings > Menus draws it as the first switch of its card")
        return row
    }

    public static func read(_ root: JSONValue) -> ContextMenusSetting {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ContextMenusSetting {
        var setting = ContextMenusSetting()
        if let show = root.value(at: showCustomizeItemPath) {
            if let value = show.boolValue { setting.showsCustomizeItem = value } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: showCustomizeItemPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        guard let layouts = root.value(at: layoutsPath) else { return setting }
        let id = layoutsPath.joined(separator: ".")
        guard let members = layouts.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an object of menu layouts"))
            return setting
        }
        for (name, value) in members {
            guard let context = ActionMenuContext(rawValue: name) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(id).\(name)", message: "no right-click menu with this name"))
                continue
            }
            guard let layout = layout(value) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(id).\(name)",
                                                      message: "expected {\"items\": [...], \"hidden\": [...]}: row keys, \"-\" and {\"key\", \"title\", \"items\"} submenus"))
                continue
            }
            setting.layouts[context] = layout
        }
        return setting
    }

    /// The deepest submenu nesting and the most entries a layout may hold: a hand-edited file
    /// cannot make every right-click walk an unbounded tree.
    static let maxDepth = 8
    static let maxEntries = 2_000

    /// A layout object (cmux.json, or a Settings > Menus write): `items`, the menu as a tree (a row
    /// key, `-`, or `{"key", "title"?, "items"}` for a submenu), and `hidden` keys. The first
    /// shape, `top` (keys) and `more` (keys moved into More), still reads. Nil for anything else.
    public static func layout(_ value: JSONValue) -> ContextMenuLayout? {
        guard value.objectValue != nil else { return nil }
        var count = 0
        func keys(_ list: JSONValue?) -> [String]? {
            guard let items = list?.arrayValue else { return nil }
            let keys = items.compactMap(\.stringValue)
            count += keys.count
            return keys.count == items.count && count <= maxEntries ? keys : nil
        }
        func nodes(_ list: JSONValue?, depth: Int) -> [ContextMenuLayout.Node]? {
            guard depth <= maxDepth, let items = list?.arrayValue else { return nil }
            var result: [ContextMenuLayout.Node] = []
            for item in items {
                count += 1
                guard count <= maxEntries else { return nil }
                if let key = item.stringValue {
                    result.append(key == ContextMenuLayout.separator ? .separator : .item(key))
                } else if let key = item["key"]?.stringValue, let children = nodes(item["items"] ?? .array([]), depth: depth + 1) {
                    let title = item["title"]?.stringValue
                    if ContextMenuLayout.isGroup(key), title == nil { return nil }
                    result.append(.folder(key: key, title: title, items: children))
                } else {
                    return nil
                }
            }
            return result
        }
        let hidden = value["hidden"] == nil ? [] : keys(value["hidden"])
        guard let hidden else { return nil }
        if value["items"] != nil {
            guard let items = nodes(value["items"], depth: 0) else { return nil }
            return ContextMenuLayout(items: items, hidden: hidden)
        }
        // The first shape: a top level of keys, and More's leading rows.
        guard let top = keys(value["top"]) else { return nil }
        let more = value["more"] == nil ? [] : keys(value["more"])
        guard let more else { return nil }
        var items: [ContextMenuLayout.Node] = top.map { key in
            if key == ContextMenuLayout.separator { return .separator }
            return key.hasPrefix("folder:") ? .folder(key: key, title: nil, items: []) : .item(key)
        }
        if !more.isEmpty {
            let moved = more.map(ContextMenuLayout.Node.item)
            if let at = items.firstIndex(where: { $0.key == ContextMenuLayout.moreKey }) {
                items[at] = .folder(key: ContextMenuLayout.moreKey, title: nil, items: moved + [.separator])
            } else {
                items += [.separator, .folder(key: ContextMenuLayout.moreKey, title: nil, items: moved + [.separator])]
            }
        }
        return ContextMenuLayout(items: items, hidden: hidden)
    }

    /// The value to write for `layout`.
    public static func value(_ layout: ContextMenuLayout) -> JSONValue {
        var members: [String: JSONValue] = ["items": .array(layout.items.map(nodeValue))]
        if !layout.hidden.isEmpty { members["hidden"] = .array(layout.hidden.map(JSONValue.string)) }
        return .object(members)
    }

    /// One tree entry as cmux.json holds it.
    public static func nodeValue(_ node: ContextMenuLayout.Node) -> JSONValue {
        switch node {
        case .separator: .string(ContextMenuLayout.separator)
        case .item(let key): .string(key)
        case .folder(let key, let title, let items):
            .object(["key": .string(key), "items": .array(items.map(nodeValue))].merging(title.map { ["title": .string($0)] } ?? [:]) { $1 })
        }
    }
}

extension SettingsController {
    /// Saves the person's arrangement of `context`'s menu; nil (Reset) removes it, so the menu
    /// follows the app's generated one again. Settings > Menus calls this on the person's gesture only.
    public func setContextMenuLayout(_ layout: ContextMenuLayout?, for context: ActionMenuContext) async throws {
        let path = ContextMenusSetting.layoutsPath + [context.rawValue]
        guard let layout else { return try await removePruning(path) }
        try await set(ContextMenusSetting.value(layout), at: path)
    }

    /// Whether whole right-click menus end with Customize Menu…; true (the default) removes the key.
    public func setShowsCustomizeMenuItem(_ show: Bool) async throws {
        if show { return try await removePruning(ContextMenusSetting.showCustomizeItemPath) }
        try await set(.bool(false), at: ContextMenusSetting.showCustomizeItemPath)
    }
}
