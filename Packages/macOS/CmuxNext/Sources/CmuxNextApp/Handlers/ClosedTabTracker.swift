import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Observation

/// Feeds `ClosedTabHistory` from the daemon store and reopens closed tabs.
/// Observes structure only (which tab is in which pane); a closed tab's cwd
/// and URL are read from the last `TabModel` seen, which the store leaves
/// untouched after removal. Session-local browser tabs are not tracked.
final class ClosedTabTracker {
    private unowned let services: AppServices
    private var history = ClosedTabHistory()
    private var lastSeen: [String: TabModel] = [:]
    private var generation: String?
    private var observation: Task<Void, Never>?

    private struct Structure: Sendable {
        var tabs: [(tab: TabModel, record: ClosedTabHistory.Record)]
        var live: Set<String>
        var generation: String?
        var connected: Bool
    }

    init(services: AppServices) {
        self.services = services
        let store = services.daemon.store
        observation = Task { [weak self] in
            for await structure in Observations({ Self.structure(of: store) }) {
                self?.apply(structure)
            }
        }
    }

    deinit { observation?.cancel() }

    private static func structure(of store: DaemonStore) -> Structure {
        var tabs: [(TabModel, ClosedTabHistory.Record)] = []
        for workspace in store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for (index, tab) in pane.tabs.enumerated() {
                        let kind: ClosedTabHistory.Record.Kind
                        switch tab.kind {
                        case .pty: kind = .terminal
                        case .browser: kind = .browser
                        default: continue
                        }
                        tabs.append((tab, ClosedTabHistory.Record(kind: kind, tabID: tab.id, paneID: pane.id,
                                                                  workspaceID: workspace.id, index: index)))
                    }
                }
            }
        }
        let connected = if case .connected = store.connectionState { true } else { false }
        return Structure(tabs: tabs, live: Set(store.workspaces.map(\.id)), generation: store.generation?.rawValue,
                         connected: connected)
    }

    private func apply(_ structure: Structure) {
        guard structure.connected else { return }
        if structure.generation != generation {
            generation = structure.generation
            history.resetBaseline()
        }
        let previous = lastSeen
        history.observe(structure.tabs.map(\.record), liveWorkspaces: structure.live) { record in
            var record = record
            record.cwd = previous[record.tabID]?.cwd
            record.url = previous[record.tabID]?.url
            return record
        }
        lastSeen = Dictionary(structure.tabs.map { ($0.tab.id, $0.tab) }, uniquingKeysWith: { first, _ in first })
    }

    func popLast() -> ClosedTabHistory.Record? {
        history.popLast()
    }

    /// Reopens `record` at its old position in its old pane, else in `fallback`.
    func reopen(_ record: ClosedTabHistory.Record, fallback: PaneController?) {
        let panes = services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes)
        let paneModel = panes.first { $0.id == record.paneID } ?? fallback?.pane
        guard let paneModel else {
            services.registry.refuse(RefusalStrings.closedTabPaneGone)
            return
        }
        let controller = services.paneController(for: paneModel)
        switch record.kind {
        case .browser:
            guard let controller else {
                services.registry.refuse(RefusalStrings.browserReopenNeedsWindow)
                return
            }
            controller.newBrowserTab(url: record.url.flatMap(URL.init(string:)))
        case .terminal:
            guard let connection = services.daemon.connection else {
                services.registry.refuse(MiscHandlerStrings.daemonOffline)
                return
            }
            let handle = paneModel.handle, cwd = record.cwd, index = record.index
            Task {
                do {
                    let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd))
                    _ = try await connection.moveTab(created.surface, to: handle, index: index)
                    if let controller {
                        controller.pendingSelectSurface = created.surface
                        controller.apply(controller.snapshot())
                    }
                } catch {
                    services.daemon.logger.error("reopen-closed-tab failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
