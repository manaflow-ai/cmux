public import Foundation

/// Manifest v2 `contributes.toolbarItems` (app-platform.md 17,
/// titlebar-area.md 3): a button, a menu button or a small app view in the
/// top-left toolbar band. App items follow the built-in items (never left of
/// the sidebar toggle); `overrides` is an alternative for a built-in item that
/// the user picks in Settings, never applied silently. The Rust validator
/// (`cmux-app-manifest`) checks the rules.
public nonisolated struct AppToolbarItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case button
        case menu
        /// A fixed-size slot rendered by the app's page at
        /// `cmux-page://<app>/toolbar/<id>`.
        case view
    }

    /// One of the app's catalog ops, or a catalog action id, with arguments.
    public struct Action: Sendable, Hashable {
        public var op: String
        public var args: AppJSON?
    }

    public struct MenuEntry: Sendable, Hashable {
        public var title: AppLocalizedText
        public var action: Action
    }

    public var id: String
    public var kind: Kind
    public var title: AppLocalizedText
    public var icon: AppIcon?
    public var action: Action?
    public var items: [MenuEntry]
    /// View only: slot width in points (at most 160).
    public var width: Int?
    public var order: Int?
    public var when: String?
    /// The built-in item (`nav.back`, `nav.forward`) this button can replace.
    public var overrides: String?

    /// The items under `contributes.toolbarItems` of a manifest document.
    static func list(_ manifest: AppJSON) -> [AppToolbarItem] {
        manifest["contributes"]?["toolbarItems"]?.arrayValue?.compactMap(AppToolbarItem.init(json:)) ?? []
    }

    init?(json: AppJSON) {
        guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let title = AppLocalizedText(json: json["title"]) else { return nil }
        self.id = id
        self.kind = kind
        self.title = title
        icon = AppIcon(json: json["icon"])
        action = Self.action(json["action"])
        items = json["items"]?.arrayValue?.compactMap { entry in
            guard let title = AppLocalizedText(json: entry["title"]), let action = Self.action(entry["action"]) else { return nil }
            return MenuEntry(title: title, action: action)
        } ?? []
        width = json["width"]?.numberValue.map { Int($0) }
        order = json["order"]?.numberValue.map { Int($0) }
        when = json["when"]?.stringValue
        overrides = json["overrides"]?.stringValue
    }

    private static func action(_ json: AppJSON?) -> Action? {
        guard let op = json?["op"]?.stringValue else { return nil }
        return Action(op: op, args: json?["args"])
    }
}
