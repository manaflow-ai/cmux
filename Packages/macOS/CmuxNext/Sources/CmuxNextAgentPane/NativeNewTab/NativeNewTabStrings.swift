import Foundation

/// The native New Tab page's localized labels.
nonisolated struct NativeNewTabStrings {
    var placeholder: String {
        String(localized: "agentPane.nativeNewTab.placeholder", defaultValue: "Ask, search, URL or !command", bundle: .localizedModule)
    }
    var terminal: String { String(localized: "agentPane.nativeNewTab.terminal", defaultValue: "Terminal", bundle: .localizedModule) }
    var browser: String { String(localized: "agentPane.nativeNewTab.browser", defaultValue: "Browser", bundle: .localizedModule) }
    var agent: String { String(localized: "agentPane.nativeNewTab.agent", defaultValue: "Agent", bundle: .localizedModule) }
    func ask(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.ask", defaultValue: "Ask: %@", bundle: .localizedModule), text)
    }
    func run(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.run", defaultValue: "Run: %@", bundle: .localizedModule), text)
    }
    func open(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.open", defaultValue: "Open or search: %@", bundle: .localizedModule), text)
    }
    var switchToTab: String { String(localized: "agentPane.nativeNewTab.switchToTab", defaultValue: "Switch to tab", bundle: .localizedModule) }
    var workspace: String { String(localized: "agentPane.nativeNewTab.workspace", defaultValue: "Workspace", bundle: .localizedModule) }
    /// "Codex in ~/fun/cmux": an agent's start row.
    func start(_ agent: String, _ folder: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.start", defaultValue: "%1$@ in %2$@", bundle: .localizedModule), agent, folder)
    }
    var startHint: String { String(localized: "agentPane.nativeNewTab.startHint", defaultValue: "Start", bundle: .localizedModule) }
    var openChat: String { String(localized: "agentPane.nativeNewTab.openChat", defaultValue: "Open chat", bundle: .localizedModule) }
    var command: String { String(localized: "agentPane.nativeNewTab.command", defaultValue: "Command", bundle: .localizedModule) }

    func title(_ kind: AgentPaneTabKind) -> String {
        switch kind {
        case .terminal: terminal
        case .browser: browser
        case .agent: agent
        }
    }
}
