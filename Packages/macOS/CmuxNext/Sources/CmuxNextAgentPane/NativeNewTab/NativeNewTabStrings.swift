import Foundation

/// The native New Tab page's localized labels.
nonisolated struct NativeNewTabStrings {
    var placeholder: String {
        String(localized: "agentPane.nativeNewTab.placeholder", defaultValue: "Ask, search, or type a URL or !command", bundle: .l10n)
    }
    var terminal: String { String(localized: "agentPane.nativeNewTab.terminal", defaultValue: "Terminal", bundle: .l10n) }
    var browser: String { String(localized: "agentPane.nativeNewTab.browser", defaultValue: "Browser", bundle: .l10n) }
    var agent: String { String(localized: "agentPane.nativeNewTab.agent", defaultValue: "Agent", bundle: .l10n) }
    func ask(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.ask", defaultValue: "Ask: %@", bundle: .l10n), text)
    }
    func run(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.run", defaultValue: "Run: %@", bundle: .l10n), text)
    }
    func open(_ text: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.open", defaultValue: "Open or search: %@", bundle: .l10n), text)
    }
    var switchToTab: String { String(localized: "agentPane.nativeNewTab.switchToTab", defaultValue: "Switch to tab", bundle: .l10n) }
    var workspace: String { String(localized: "agentPane.nativeNewTab.workspace", defaultValue: "Workspace", bundle: .l10n) }
    /// "Codex in ~/fun/cmux": an agent's start row.
    func start(_ agent: String, _ folder: String) -> String {
        String(format: String(localized: "agentPane.nativeNewTab.start", defaultValue: "%1$@ in %2$@", bundle: .l10n), agent, folder)
    }
    var startHint: String { String(localized: "agentPane.nativeNewTab.startHint", defaultValue: "Start", bundle: .l10n) }
    var openChat: String { String(localized: "agentPane.nativeNewTab.openChat", defaultValue: "Open chat", bundle: .l10n) }
    var command: String { String(localized: "agentPane.nativeNewTab.command", defaultValue: "Command", bundle: .l10n) }

    func title(_ kind: AgentPaneTabKind) -> String {
        switch kind {
        case .terminal: terminal
        case .browser: browser
        case .agent: agent
        }
    }
}
