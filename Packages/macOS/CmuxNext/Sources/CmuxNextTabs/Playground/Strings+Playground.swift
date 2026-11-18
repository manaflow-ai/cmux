import Foundation

/// The tab bar playground's own strings (``TabBarPlaygroundView``, DEV and NIGHTLY).
extension Strings {
    static var playgroundWindowTitle: String { String(localized: "tabs.playground.windowTitle", defaultValue: "Tab Bar Playground", bundle: .l10n) }
    static var playgroundLight: String { String(localized: "tabs.playground.light", defaultValue: "Light", bundle: .l10n) }
    static var playgroundDark: String { String(localized: "tabs.playground.dark", defaultValue: "Dark", bundle: .l10n) }
    static var playgroundTerminal: String { String(localized: "tabs.playground.kind.terminal", defaultValue: "Terminal", bundle: .l10n) }
    static var playgroundBrowser: String { String(localized: "tabs.playground.kind.browser", defaultValue: "Browser", bundle: .l10n) }
    static var playgroundAgentChat: String { String(localized: "tabs.playground.kind.agentChat", defaultValue: "Agent Chat", bundle: .l10n) }
    /// A tab count choice ("26 tabs").
    static func playgroundTabCount(_ count: Int) -> String {
        String(format: String(localized: "tabs.playground.tabCount", defaultValue: "%lld tabs", bundle: .l10n), count)
    }
    /// The caption of the design the app ships ("Shipped: …").
    static func playgroundShipped(_ name: String) -> String {
        String(format: String(localized: "tabs.playground.shipped", defaultValue: "Shipped: %@", bundle: .l10n), name)
    }
    /// A Corner Radius row's name ("Radius 10 pt, padding 2 pt").
    static func playgroundCornerName(outer: CGFloat, padding: CGFloat) -> String {
        String(format: String(localized: "tabs.playground.corner.name", defaultValue: "Radius %1$@ pt, padding %2$@ pt", bundle: .l10n),
               points(outer), points(padding))
    }
    /// A Corner Radius row's caption: the nested radius it derives ("Tabs and inner fills: 8 pt").
    static func playgroundCornerCaption(inner: CGFloat) -> String {
        String(format: String(localized: "tabs.playground.corner.caption", defaultValue: "Tabs and inner fills: %@ pt", bundle: .l10n), points(inner))
    }
    /// The Folder Corners page's rows (``FolderCornerPlaygroundVariants``).
    static var playgroundFolderOneColor: String {
        String(localized: "tabs.playground.folder.oneColor", defaultValue: "One Color", bundle: .l10n)
    }
    static var playgroundFolderMiddle: String {
        String(localized: "tabs.playground.folder.middle", defaultValue: "Subtle Tone, a middle tab selected", bundle: .l10n)
    }
    static var playgroundFolderFirstLeft: String {
        String(localized: "tabs.playground.folder.firstLeft", defaultValue: "Subtle Tone, the first tab selected, sidebar on the left", bundle: .l10n)
    }
    static var playgroundFolderFirstRight: String {
        String(localized: "tabs.playground.folder.firstRight", defaultValue: "Subtle Tone, the first tab selected, sidebar on the right", bundle: .l10n)
    }
    static var playgroundFolderFullscreen: String {
        String(localized: "tabs.playground.folder.fullscreen", defaultValue: "Subtle Tone, full screen", bundle: .l10n)
    }
    /// A sample tab's title ("Tab 2").
    static func playgroundTabTitle(_ number: Int) -> String {
        String(format: String(localized: "tabs.playground.folder.tabTitle", defaultValue: "Tab %lld", bundle: .l10n), number)
    }
    private static func points(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}
