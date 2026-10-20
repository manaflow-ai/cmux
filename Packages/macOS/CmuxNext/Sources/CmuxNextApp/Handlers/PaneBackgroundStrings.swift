/// Refusals of the pane background actions (`PaneBackgroundHandlers`).
struct PaneBackgroundStrings {
    static var badBackground: String {
        String(localized: "handlers.paneBackground.badBackground",
               defaultValue: "Not a background. Use inherit, none, daily, desktop, a painting, or a system: or file: path.",
               table: "MiscHandlers", bundle: .module)
    }
    static var badTint: String {
        String(localized: "handlers.paneBackground.badTint", defaultValue: "Not a tint. Use none, a color name, or #RRGGBB.",
               table: "MiscHandlers", bundle: .module)
    }
    static var noDurablePane: String {
        String(localized: "handlers.paneBackground.noDurablePane",
               defaultValue: "This pane cannot keep its own background: its session is too old. Update cmux on that machine.",
               table: "MiscHandlers", bundle: .module)
    }
}
