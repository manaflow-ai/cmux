import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
import Observation

/// Search Tabs (`tab.search`, Cmd-Shift-A): the palette page over every
/// tab with recently closed tabs below. Keyboard, menu and palette runs
/// open it (with `query` typed when given). A CLI or MCP run opens it only
/// with `focus: true`, because it takes the keyboard; agents read results
/// from the `tabs.search` socket method instead (`TabSearchControl`).
enum TabSearchHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let source = AppTabSearchSource(services: services)
        let watcher = TabSearchWatcher(services: services)
        let page = { (query: String) -> PalettePageSpec in
            watcher.start()
            return PalettePageSpec.tabSearch(source: source, query: query)
        }
        services.palette.sources.actionPages["tab.search"] = { page("") }
        registry.bind("tab.search", run: { invocation in
            guard invocation.allowsViewChange else { throw ActionFailure(message: TabSearchAppStrings.needsFocus) }
            services.palette.show(page: page(invocation["query"]?.stringValue ?? ""), relativeTo: context.activeWindow?.window)
        })
    }
}

/// Re-reads the Search Tabs page when tabs open or close on any machine
/// while the page is shown (event driven: Observation of the mirror's
/// structure). Stops itself once the page is gone.
final class TabSearchWatcher {
    private unowned let services: AppServices
    private var task: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        let machines = services.machines
        task = Task { [weak self] in
            var first = true
            for await _ in Observations({ Self.structure(machines.daemons) }) {
                guard let self else { return }
                if first {
                    first = false
                    continue
                }
                guard let palette = self.services.palette as PaletteController?, palette.isVisible,
                      palette.model.currentPageID == PalettePageSpec.tabSearchID else { return self.stop() }
                palette.model.reload()
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    /// Which tabs exist where; titles and other fields do not count.
    private static func structure(_ daemons: [DaemonService]) -> [String] {
        daemons.flatMap { daemon in
            daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap { pane in pane.tabs.map { "\(daemon.machineID)/\(pane.id)/\($0.id)" } }
        }
    }
}
