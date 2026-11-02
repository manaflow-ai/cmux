public import CmuxNextActions

/// Settings > Menus: every right-click menu's rows and the person's arrangement of it
/// (``ContextMenuLayout``), saved in cmux.json `contextMenus` (``ContextMenusSetting``). The App's
/// page route serves it and admits only the person's gesture on Settings.
///
/// - ``hostJSON`` is the host lists' `context_menus`: each menu's rows, its generated layout
///   (what Reset draws), the layout drawn now, and whether menus end with Customize Menu…. A
///   row's icon is `cmux-page://cmux.settings/symbol/<name>`.
/// - `set {menu, layout}` saves a layout; a null layout, or one that draws the generated menu, removes it.
/// - `show_item {show}` turns the Customize Menu… row on or off.
@MainActor
public struct ContextMenusSettingsPage {
    public nonisolated static let prefix = "cmux.settings.context_menus."

    /// A request the page should not have sent.
    public struct InvalidRequest: Error, Sendable {
        public let message: String
    }

    private let registry: ActionRegistry
    private let settings: SettingsController

    public init(registry: ActionRegistry, settings: SettingsController) {
        self.registry = registry
        self.settings = settings
    }

    /// The host lists' `context_menus`. It reads the registry's layouts, so the page's host-lists
    /// watch re-sends it after cmux.json changes.
    public var hostJSON: JSONValue {
        [
            "show_customize_item": .bool(registry.showsCustomizeMenuItem),
            "menus": .array(registry.contextMenuEditorMenus().map(Self.menuJSON)),
        ]
    }

    /// Whether `op` is one of this page's ops.
    public func handles(_ op: String) -> Bool {
        op == Self.prefix + "set" || op == Self.prefix + "show_item"
    }

    /// Runs `op` (``handles(_:)``) with `params`.
    public func run(_ op: String, params: JSONValue) async throws {
        if op == Self.prefix + "show_item" {
            guard let show = params["show"]?.boolValue else { throw InvalidRequest(message: "show is required") }
            return try await settings.setShowsCustomizeMenuItem(show)
        }
        guard let name = params["menu"]?.stringValue, let menu = ActionMenuContext(rawValue: name) else {
            throw InvalidRequest(message: "menu must name a right-click menu")
        }
        guard let value = params["layout"] else { throw InvalidRequest(message: "layout is required (null resets the menu)") }
        let generated = ContextMenuCatalog.shared.entries(for: menu)
        var layout: ContextMenuLayout?
        if value != .null {
            guard let parsed = ContextMenusSetting.layout(value) else {
                throw InvalidRequest(message: "layout must be {items, hidden}: row keys, \"-\" and {key, title, items} submenus")
            }
            // Saved as drawn: keys the app does not place are dropped, and the generated menu is
            // no layout at all, so later app changes reach it.
            let normalized = parsed.normalized(against: generated)
            layout = normalized == .generated(generated) ? nil : normalized
        }
        try await settings.setContextMenuLayout(layout, for: menu)
    }

    private static func menuJSON(_ menu: ContextMenuEditorMenu) -> JSONValue {
        [
            "id": .string(menu.context.rawValue),
            "title": .string(menu.title),
            "area": .string(menu.area.rawValue),
            "customized": .bool(menu.isCustomized),
            "rows": .array(menu.rows.map { row in
                [
                    "key": .string(row.key), "title": .string(row.title), "kind": .string(row.kind.rawValue),
                    "symbol": row.symbol.map(JSONValue.string) ?? .null, "home": row.home.map(JSONValue.string) ?? .null,
                ]
            }),
            "generated": layoutJSON(menu.generated),
            "layout": layoutJSON(menu.layout),
        ]
    }

    private static func layoutJSON(_ layout: ContextMenuLayout) -> JSONValue {
        [
            "items": .array(layout.items.map(ContextMenusSetting.nodeValue)),
            "hidden": .array(layout.hidden.map(JSONValue.string)),
        ]
    }
}
