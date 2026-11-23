/// `sidebar.sections.hidden` and `sidebar.sections.order` in cmux-next.json: sidebar section ids
/// (or their stable keys), the overlay cmux-layout-reducer's sidebar_section_customization.rs
/// plans. ``SidebarProjectionCustomizationResolver`` reads both from `sidebar.sections`; these rows
/// make them settings, so the palette, `cmux settings`, MCP and a look can set them.
public nonisolated struct SidebarSectionIDsSetting: Sendable {
    public nonisolated init() {}
    // The paths and defaults are generated from schemas/settings/source/sidebar.json.

    /// The most ids a list holds, and the longest id (sidebar_section_customization.rs).
    public static let maxEntries = 256
    public static let maxIDLength = 128

    /// Whether `value` is a list of distinct ids of 1 to 128 characters, at most 256 of them: a
    /// list the planner reads with no problem (the same rule as cmux-config
    /// `is_sidebar_section_ids` and webviews validate.ts `isSidebarSectionIds`).
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
