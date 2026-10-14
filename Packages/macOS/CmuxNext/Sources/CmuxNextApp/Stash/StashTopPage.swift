import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory
import CmuxNextIcons
import CmuxNextStash

extension InternalPageID {
    /// Stashed Tabs as a top page: the sidebar item, Show Stashed Tabs and the New Tab link.
    static let stashed = InternalPageID(rawValue: "stashed")
}

/// The Stashed page as a top page: one view per key over the app's one stash model.
final class StashTopPage: InternalPageProvider {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .stashed }
    var title: String { StashStrings.title }
    var symbol: String { "tray.full" }
    var icon: IconName? { .tabgroupSave }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let stash = services?.historyPage.stash else { return NSView() }
        return StashPageHostView(model: stash.model, draft: stash.draft(for: key))
    }

    func tabClosed(_ key: String) { services?.historyPage.stash.dropDraft(key) }
}

/// The App's side of Stash (CmuxNextStash): this Mac's daemon, the windows and the pages.
final class StashAppHost: StashHost {
    private weak var services: AppServices?
    let registry: ActionRegistry
    let localDaemon: DaemonService

    init(_ services: AppServices) {
        self.services = services
        registry = services.registry
        localDaemon = services.daemon
    }

    var stashImportEngine: String {
        if case .open(let choice)? = services?.cache.browserTabs.resolve(requested: nil) { return choice.engine.rawValue }
        return BrowserEngineTag.webkit.rawValue
    }
    var stashRestorePane: ResourceID? {
        guard let services, let focused = services.windows.active?.focusedPane?.pane,
              services.machines.daemon(forPane: focused).isLocal else { return nil }
        return focused.resourceID
    }
    var stashCountPages: [String: AgentPaneView] { services?.agentTabs.views ?? [:] }
    var stashCountStandalonePages: [AgentPaneView] { services?.agentTabs.standaloneViews.allObjects ?? [] }

    func stashOrigin(_ invocation: ActionInvocation) -> StashOrigin? {
        guard let services, let (tab, pane) = AppActionContext(services: services).daemonTab(invocation) else { return nil }
        let daemon = services.machines.daemon(forPane: pane)
        let workspace = daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
        let strip = services.paneController(for: pane).map { controller in controller.orderedIDs.compactMap { controller.tab($0) } }
        return StashOrigin(tab: tab, workspace: workspace, daemon: daemon, strip: strip ?? pane.tabs)
    }

    func showRestored(_ reopened: StateResourceClient.ReopenedItem, asWorkspace: Bool) {
        guard let services else { return }
        DaemonClosedHistory.show(reopened, kind: asWorkspace ? .workspace : .tab, daemon: localDaemon, services: services)
    }

    func showStashedPage() -> String? { services.flatMap { TopPages.show(.page(.stashed), services: $0) } }
}
