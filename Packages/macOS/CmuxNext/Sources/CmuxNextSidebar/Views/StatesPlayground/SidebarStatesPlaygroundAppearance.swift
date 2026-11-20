import AppKit

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one of the playground's two sheets, light or dark.
enum SidebarStatesPlaygroundAppearance: String, CaseIterable, Sendable {
    /// The light sheet (`aqua`, the light theme of ``SidebarStatesPlaygroundThemes``).
    case light
    /// The dark sheet (`darkAqua`, the dark theme of ``SidebarStatesPlaygroundThemes``).
    case dark

    /// The AppKit appearance the sheet's sidebars draw in.
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }

    /// The sheet's title.
    var title: String {
        switch self {
        case .light: String(localized: "sidebar.statesPlayground.light", defaultValue: "Light", bundle: .module)
        case .dark: String(localized: "sidebar.statesPlayground.dark", defaultValue: "Dark", bundle: .module)
        }
    }
}
