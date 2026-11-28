// Browser actions that guard agent access to pages (plans/cmux-next/passwords.md, 3.4).

nonisolated extension BrowserActionCatalog {
    static func agentGuardDescriptors() -> [ActionDescriptor] {
        var allowAgent = ActionDescriptor(
            id: "browser.allowAgentWithExtensions",
            title: String(localized: "action.browser.allowAgentWithExtensions", defaultValue: "Allow Agents in This Tab…", bundle: .module),
            keywords: ["agent", "automation", "extension", "password", "allow"],
            category: .browser, symbol: "exclamationmark.shield", surfaces: [.palette], targets: [.pane],
            destructive: true
        )
        // Only the person may lift the extension guard for agents.
        allowAgent.isPersonOnly = true
        return [allowAgent]
    }
}
