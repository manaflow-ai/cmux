import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextSettings
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
    /// The page every agent tab loads: the bundled file, or in Debug builds
    /// the dev server `CMUX_NEXT_AGENT_PANE_DEV_URL` names (nil only when the
    /// bundled page is missing).
    private let source: AgentPaneSource?
    /// `CMUX_NEXT_AGENT_PANE_FULL_RATE=1` (Debug builds): panes render at the
    /// display's full rate, for measuring it (`AgentPaneView.init`).
    private let rendersAtFullRate: Bool
    /// `~/.config/cmux/agent-pane/` hot reload, watched while any agent tab
    /// has a view.
    private let customization: AgentPaneCustomizationWatcher
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
            host = AcpmuxHost { AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bin, environment: environment) }
        }
        // Release loads only the bundled page; the dev server is for Debug
        // and tagged builds (webviews/src/agent-session/acpmux/README.md).
        #if DEBUG
        let allowsDevServer = true
        #else
        let allowsDevServer = false
        #endif
        #if DEBUG
        rendersAtFullRate = environment["CMUX_NEXT_AGENT_PANE_FULL_RATE"] == "1"
        #else
        rendersAtFullRate = false
        #endif
        source = AgentPaneSource.resolve(
            environment: environment, bundledPage: AgentPaneView.bundledPage, allowsDevServer: allowsDevServer
        )
        customization = AgentPaneCustomizationWatcher(
            directory: AgentPaneCustomization.directory(configFile: CmuxConfigFile.defaultURL(environment: environment))
        )
        customization.onChange = { [weak self] value in
            guard let self else { return }
            for view in views.values { view.customization = value }
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
        StripTabItem(id: StripTabID(key), title: AgentPaneModel.tabTitle, subtitle: nil,
                     icon: .symbol("bubble.left.and.text.bubble.right"), isBusy: false)
    }

    /// The tab's pane view, made on first show.
    func view(for key: String) -> AgentPaneView? {
        if let view = views[key] { return view }
        guard tabsByPane.values.contains(where: { $0.contains(key) }) else { return nil }
        let model = AgentPaneModel(host: host, sessionId: sessions[key])
        model.onSessionChange = { [weak self] session in self?.sessions[key] = session }
        guard let source, let view = AgentPaneView(model: model, source: source, rendersAtFullRate: rendersAtFullRate) else { return nil }
        view.customization = customization.current
        views[key] = view
        customization.start()
        return view
    }

    func existingView(_ key: String) -> AgentPaneView? { views[key] }

    /// The tab closed: stop its page and forget it.
    func close(_ key: String) {
        for pane in tabsByPane.keys { tabsByPane[pane]?.removeAll { $0 == key } }
        tabsByPane = tabsByPane.filter { !$0.value.isEmpty }
        views.removeValue(forKey: key)?.close()
        sessions[key] = nil
        stopCustomizationWhenUnused()
    }

    /// The pane closed: stop every agent tab it listed.
    func closePane(_ paneKey: String) {
        for key in tabsByPane.removeValue(forKey: paneKey) ?? [] {
            views.removeValue(forKey: key)?.close()
            sessions[key] = nil
        }
        stopCustomizationWhenUnused()
    }

    private func stopCustomizationWhenUnused() {
        if views.isEmpty { customization.stop() }
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
