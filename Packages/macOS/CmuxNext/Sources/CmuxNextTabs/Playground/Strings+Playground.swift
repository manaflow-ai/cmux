import Foundation

/// The tab bar playground's own strings (``TabBarPlaygroundView``, DEV and NIGHTLY).
extension Strings {
    static var playgroundWindowTitle: String { String(localized: "tabs.playground.windowTitle", defaultValue: "Tab Bar Playground", bundle: .localizedModule) }
    static var playgroundLight: String { String(localized: "tabs.playground.light", defaultValue: "Light", bundle: .localizedModule) }
    static var playgroundDark: String { String(localized: "tabs.playground.dark", defaultValue: "Dark", bundle: .localizedModule) }
    static var playgroundTerminal: String { String(localized: "tabs.playground.kind.terminal", defaultValue: "Terminal", bundle: .localizedModule) }
    static var playgroundBrowser: String { String(localized: "tabs.playground.kind.browser", defaultValue: "Browser", bundle: .localizedModule) }
    static var playgroundAgentChat: String { String(localized: "tabs.playground.kind.agentChat", defaultValue: "Agent Chat", bundle: .localizedModule) }
    /// A tab count choice ("26 tabs").
    static func playgroundTabCount(_ count: Int) -> String {
        String(format: String(localized: "tabs.playground.tabCount", defaultValue: "%lld tabs", bundle: .localizedModule), count)
    }
    /// The caption of the design the app ships ("Shipped: …").
    static func playgroundShipped(_ name: String) -> String {
        String(format: String(localized: "tabs.playground.shipped", defaultValue: "Shipped: %@", bundle: .localizedModule), name)
    }
    /// A Corner Radius row's name ("Radius 10 pt, padding 2 pt").
    static func playgroundCornerName(outer: CGFloat, padding: CGFloat) -> String {
        String(format: String(localized: "tabs.playground.corner.name", defaultValue: "Radius %1$@ pt, padding %2$@ pt", bundle: .localizedModule),
               points(outer), points(padding))
    }
    /// A Tab Max Width row's name ("Max tab width 201 pt", ``TabMaxWidthPlaygroundVariants``).
    static func playgroundTabMaxWidth(_ width: CGFloat) -> String {
        String(format: String(localized: "tabs.playground.maxWidth.name", defaultValue: "Max tab width %@ pt", bundle: .localizedModule), points(width))
    }
    /// A Corner Radius row's caption: the nested radius it derives ("Tabs and inner fills: 8 pt").
    static func playgroundCornerCaption(inner: CGFloat) -> String {
        String(format: String(localized: "tabs.playground.corner.caption", defaultValue: "Tabs and inner fills: %@ pt", bundle: .localizedModule), points(inner))
    }
    /// The Folder Corners page's rows (``FolderCornerPlaygroundVariants``).
    static var playgroundFolderOneColor: String {
        String(localized: "tabs.playground.folder.oneColor", defaultValue: "One Color", bundle: .localizedModule)
    }
    static var playgroundFolderMiddle: String {
        String(localized: "tabs.playground.folder.middle", defaultValue: "Subtle Tone, a middle tab selected", bundle: .localizedModule)
    }
    static var playgroundFolderFirstLeft: String {
        String(localized: "tabs.playground.folder.firstLeft", defaultValue: "Subtle Tone, the first tab selected, sidebar on the left", bundle: .localizedModule)
    }
    static var playgroundFolderFirstRight: String {
        String(localized: "tabs.playground.folder.firstRight", defaultValue: "Subtle Tone, the first tab selected, sidebar on the right", bundle: .localizedModule)
    }
    static var playgroundFolderFullscreen: String {
        String(localized: "tabs.playground.folder.fullscreen", defaultValue: "Subtle Tone, full screen", bundle: .localizedModule)
    }
    /// A sample tab's title ("Tab 2").
    static func playgroundTabTitle(_ number: Int) -> String {
        String(format: String(localized: "tabs.playground.folder.tabTitle", defaultValue: "Tab %lld", bundle: .localizedModule), number)
    }
    private static func points(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}
