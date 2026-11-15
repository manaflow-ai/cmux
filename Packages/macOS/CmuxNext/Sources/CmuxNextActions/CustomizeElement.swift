public import Foundation

/// One big part of the window Customize… can be about: the Rust element map's entry
/// (cmux-action-catalog `customize_elements`), read with the action catalog. The right-click
/// Customize… row passes its id as `customize.open`'s `element`; the Customize Inspector
/// (hold Option over the window) shows its title, settings and theme tokens.
public nonisolated struct CustomizeElement: Hashable, Sendable, Identifiable {
    /// The element id (`sidebar`, `tab`, `chatComposer`…).
    public let id: String
    /// Its name in the app's language.
    public let title: String
    /// The big surface it belongs to.
    public let surface: String
    /// The right-click menus (`ActionMenuContext` raw values) whose Customize… row means it.
    public let menus: [String]
    /// The settings that change it (keys without the `setting.` prefix), most used first.
    public let settings: [String]
    /// The theme tokens it paints with (`windowBackground`, `accent`…).
    public let tokens: [String]

    public init(id: String, title: String, surface: String, menus: [String], settings: [String], tokens: [String]) {
        (self.id, self.title, self.surface, self.menus, self.settings, self.tokens) = (id, title, surface, menus, settings, tokens)
    }

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        self.init(id: id, title: row["title"] as? String ?? id, surface: row["surface"] as? String ?? id,
                  menus: row["menus"] as? [String] ?? [], settings: row["settings"] as? [String] ?? [],
                  tokens: row["tokens"] as? [String] ?? [])
    }

    /// Customize… (`customize.open`), whose right-click rows pass their menu's element.
    public static let openActionID = "customize.open"
    /// Reset Element to Defaults (`customize.reset`).
    public static let resetActionID = "customize.reset"

    /// Every element, in the map's order.
    public static var all: [CustomizeElement] { RustActionCatalog.shared.customizeElements }

    /// The element with `id`.
    public static func named(_ id: String) -> CustomizeElement? { all.first { $0.id == id } }

    /// The element a right-click in `context` customizes.
    public static func element(for context: ActionMenuContext) -> CustomizeElement? {
        all.first { $0.menus.contains(context.rawValue) }
    }
}
