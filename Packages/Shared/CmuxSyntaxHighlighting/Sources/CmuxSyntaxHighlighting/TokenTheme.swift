/// Light or dark highlight.js theme used by the v1 Highlightr engine.
///
/// Surface (panel) colors stay on Ghostty `PanelAppearance`. These names only
/// select token palettes (`xcode` / `xcode-dark`).
public enum TokenTheme: Sendable, Equatable {
    /// Light token palette (`xcode`).
    case light
    /// Dark token palette (`xcode-dark`).
    case dark

    /// Highlightr theme identifier for this appearance.
    public var highlightrThemeName: String {
        switch self {
        case .light:
            return "xcode"
        case .dark:
            return "xcode-dark"
        }
    }
}
