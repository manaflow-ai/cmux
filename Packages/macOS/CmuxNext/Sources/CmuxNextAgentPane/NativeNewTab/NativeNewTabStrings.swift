import Foundation

/// The native New Tab page's localized labels.
nonisolated struct NativeNewTabStrings {
    var placeholder: String {
        String(localized: "agentPane.nativeNewTab.placeholder", defaultValue: "Ask, search, or type a URL or !command", bundle: .module)
    }
    var terminal: String { String(localized: "agentPane.nativeNewTab.terminal", defaultValue: "Terminal", bundle: .module) }
    var browser: String { String(localized: "agentPane.nativeNewTab.browser", defaultValue: "Browser", bundle: .module) }
    var agent: String { String(localized: "agentPane.nativeNewTab.agent", defaultValue: "Agent", bundle: .module) }
    func ask(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.ask", defaultValue: "Ask: %@", bundle: .module), text)
    }
    func run(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.run", defaultValue: "Run: %@", bundle: .module), text)
    }
    func open(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.open", defaultValue: "Open or search: %@", bundle: .module), text)
    }
    var switchToTab: String { String(localized: "agentPane.nativeNewTab.switchToTab", defaultValue: "Switch to tab", bundle: .module) }
    var workspace: String { String(localized: "agentPane.nativeNewTab.workspace", defaultValue: "Workspace", bundle: .module) }
    var command: String { String(localized: "agentPane.nativeNewTab.command", defaultValue: "Command", bundle: .module) }

    func title(_ kind: AgentPaneTabKind) -> String {
        switch kind {
        case .terminal: terminal
        case .browser: browser
        case .agent: agent
        }
    }
}
