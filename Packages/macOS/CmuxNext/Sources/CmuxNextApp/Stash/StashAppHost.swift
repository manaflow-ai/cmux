import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextStash

/// The App's side of Stash (CmuxNextStash): this Mac's daemon, the windows and the pages.
@MainActor
final class StashAppHost: StashHost {
    private weak var services: AppServices?
    let localDaemon: DaemonService

    init(_ services: AppServices) {
        self.services = services
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

    func showRestored(_ reopened: StateResourceClient.ReopenedItem, asWorkspace: Bool) {
        guard let services else { return }
        DaemonClosedHistory.show(reopened, kind: asWorkspace ? .workspace : .tab, daemon: localDaemon, services: services)
    }
}
