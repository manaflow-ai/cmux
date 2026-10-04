import AppKit

extension TabContent {
    /// `key`'s live content in whichever owner holds it (terminal surfaces
    /// and pages in the cache, agent tabs, internal pages, remote
    /// placeholders, conversation views, app pages). Never creates content,
    /// so any pane or diagnostic can ask without side effects.
    static func existing(_ key: String, services: AppServices) -> TabContent? {
        if let entry = services.cache.existingTerminal(key) { return .terminal(entry) }
        if let view = services.agentTabs.existingView(key) { return .agent(view) }
        if let view = services.pages.existingView(key) { return .page(view) }
        if let placeholder = services.remoteTerminals.existingPlaceholder(key) { return .placeholder(placeholder) }
        if let home = services.home.existingTabView(key) { return .conversation(home) }
        if let app = services.apps.existingTabView(key) { return .app(app) }
        return services.cache.existingBrowser(key).map(TabContent.browser)
    }
}
