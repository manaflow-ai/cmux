import Foundation

/// `actions` in cmux-next.json: commands of the person's own, by id, each a shell command or an
/// agent with a title, an icon and a target (``ConfigActionParser`` reads them;
/// ConfigActionsController registers each as `cmuxConfig.<id>` in the palette, shortcuts and the CLI):
///
/// ```json
/// "actions": {
///   "deploy": { "title": "Deploy", "command": "make deploy" },
///   "review": { "type": "agent", "agent": "claude", "args": "-p review" }
/// }
/// ```
///
/// Only the person sets it (an action runs a shell command); a customize profile carries one
/// action per key (`actions.<id>`), so two palette packs stack.
public nonisolated struct ConfigActionsSetting: Sendable {
    public init() {}

    /// Whether the app applies `value` with no diagnostic: an object of action objects the parser
    /// takes whole (the same rule as cmux-config `is_config_action` and webviews validate.ts
    /// `isConfigAction`).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .object(let entries) = value, entries.values.allSatisfy({ $0.objectValue != nil }) else { return false }
        var diagnostics: [SettingsDiagnostic] = []
        _ = ConfigActionParser.parseActions(.object(["actions": value]),
                                            configDirectory: URL(filePath: "/"), diagnostics: &diagnostics)
        return diagnostics.isEmpty
    }
}

/// `sidebar.sections.hidden` and `sidebar.sections.order` in cmux-next.json: sidebar section ids (or
/// their stable keys), the overlay cmux-layout-reducer's sidebar_section_customization.rs plans.
public nonisolated struct SidebarSectionIDsSetting: Sendable {
    public init() {}

    /// The most ids a list holds, and the longest id (sidebar_section_customization.rs).
    public static let maxEntries = 256
    public static let maxIDLength = 128

    /// Whether `value` is a list of distinct ids of 1 to 128 characters, at most 256 of them (the
    /// same rule as cmux-config `is_sidebar_section_ids` and webviews validate.ts).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .array(let items) = value, items.count <= maxEntries else { return false }
        var seen = Set<String>()
        for item in items {
            // Unicode scalars, as Rust counts `chars()`.
            guard let id = item.stringValue, !id.isEmpty, id.unicodeScalars.count <= maxIDLength,
                  seen.insert(id).inserted else { return false }
        }
        return true
    }
}
