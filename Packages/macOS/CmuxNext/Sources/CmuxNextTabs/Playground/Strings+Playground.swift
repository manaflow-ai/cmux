import Foundation

/// The tab bar playground's own strings (``TabBarPlaygroundView``, DEV and NIGHTLY).
extension Strings {
    static var playgroundWindowTitle: String { String(localized: "tabs.playground.windowTitle", defaultValue: "Tab Bar Playground", bundle: .module) }
    static var playgroundLight: String { String(localized: "tabs.playground.light", defaultValue: "Light", bundle: .module) }
    static var playgroundDark: String { String(localized: "tabs.playground.dark", defaultValue: "Dark", bundle: .module) }
    static var playgroundTerminal: String { String(localized: "tabs.playground.kind.terminal", defaultValue: "Terminal", bundle: .module) }
    static var playgroundBrowser: String { String(localized: "tabs.playground.kind.browser", defaultValue: "Browser", bundle: .module) }
    static var playgroundAgentChat: String { String(localized: "tabs.playground.kind.agentChat", defaultValue: "Agent Chat", bundle: .module) }
    /// A tab count choice ("26 tabs").
    static func playgroundTabCount(_ count: Int) -> String {
        String(format: String(localized: "tabs.playground.tabCount", defaultValue: "%lld tabs", bundle: .module), count)
    }
    /// The caption of the design the app ships ("Shipped: …").
    static func playgroundShipped(_ name: String) -> String {
        String(format: String(localized: "tabs.playground.shipped", defaultValue: "Shipped: %@", bundle: .module), name)
    }
}
