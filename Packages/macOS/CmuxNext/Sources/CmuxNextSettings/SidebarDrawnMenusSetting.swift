import Foundation

/// `sidebar.drawnMenus`: the sidebar's right-click and more-button menus open as cmux-drawn menus
/// (`GlassMenu`), which the menu look (`appearance.menu.*`) styles, instead of the system menu, which
/// cannot be restyled. Off by default: today's menus. Leo, 2026-11-19: "i think y'all also ought to
/// emulate the things for context menu styling and such".
public nonisolated struct SidebarDrawnMenusSetting: Sendable {
    // `configPath` and `fallback` (off) are generated from schemas/settings/source/sidebar.json.

    public init() {}

    /// The value in `root`: on only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}
