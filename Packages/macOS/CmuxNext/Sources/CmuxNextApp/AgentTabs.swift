import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextTabs

/// Agent chat tabs (the React acpmux pane, CmuxNextAgentPane). cmux-tui has
/// no agent tab kind yet, so like `LocalBrowserTab` they live only in this
/// app session and are not restored after relaunch; the acpmux sessions they
/// show are durable in acpmux. Ids carry `prefix` so every tab path can tell
/// them from daemon tabs.
enum LocalAgentTab {
    static let prefix = "local-agent:"
}

/// Which agent tabs each pane lists, and their pane views. One acpmux host is
/// shared by every tab, so opening several at once starts one daemon.
final class AgentTabStore {
    private let host: any AgentPaneHostProviding
    private var tabsByPane: [String: [String]] = [:]
    private var views: [String: AgentPaneView] = [:]
    /// Session each tab last showed, kept across a web content crash or a
    /// view rebuilt after the tab was released.
    private var sessions: [String: String] = [:]

    init(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if environment["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" {
            host = MockAgentPaneHost()
        } else {
            let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
            host = AcpmuxHost(environment: AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bin, environment: environment))
        }
    }

    /// Adds a new chat tab to `paneKey`'s strip and returns its id.
    func open(in paneKey: String) -> String {
        let key = LocalAgentTab.prefix + UUID().uuidString.lowercased()
        tabsByPane[paneKey, default: []].append(key)
        return key
    }

    func tabIDs(in paneKey: String) -> [String] { tabsByPane[paneKey] ?? [] }

    func stripItem(_ key: String) -> StripTabItem {
        StripTabItem(id: StripTabID(key), title: AgentPaneStrings.tabTitle, subtitle: nil,
                     icon: .symbol("bubble.left.and.text.bubble.right"), isBusy: false)
    }

    /// The tab's pane view, made on first show.
    func view(for key: String) -> AgentPaneView? {
        if let view = views[key] { return view }
        guard tabsByPane.values.contains(where: { $0.contains(key) }) else { return nil }
        let model = AgentPaneModel(host: host, sessionId: sessions[key])
        model.onSessionChange = { [weak self] session in self?.sessions[key] = session }
        guard let view = AgentPaneView(model: model) else { return nil }
        views[key] = view
        return view
    }

    func existingView(_ key: String) -> AgentPaneView? { views[key] }

    /// The tab closed: stop its page and forget it.
    func close(_ key: String) {
        for pane in tabsByPane.keys { tabsByPane[pane]?.removeAll { $0 == key } }
        tabsByPane = tabsByPane.filter { !$0.value.isEmpty }
        views.removeValue(forKey: key)?.close()
        sessions[key] = nil
    }
}

extension PaneController {
    /// New Agent Chat: a new agent tab in this pane, selected.
    func newAgentTab() {
        let key = services.agentTabs.open(in: paneKey)
        apply(snapshot())
        select(StripTabID(key))
    }
}
