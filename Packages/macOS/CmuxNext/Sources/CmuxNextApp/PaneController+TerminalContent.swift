import CmuxNextDaemon

extension PaneController {
    /// A daemon terminal tab's content: the cached surface (attached on
    /// demand), its theme, and the dead-tab overlay's Restart (`tab.restart`).
    func terminalContent(_ tab: TabModel) -> TabContent {
        let entry = BenchSpans.measure("terminal.surface") { services.cache.terminal(for: tab, daemon: daemon) }
        services.themes.terminalDidMount(entry)
        TabRestart.offer(on: entry, tab: tab, daemon: daemon, registry: services.registry)
        return .terminal(entry)
    }
}
