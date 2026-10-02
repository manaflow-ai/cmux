import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Observation

/// Feeds `ClosedTabHistory` from every machine's daemon store and reopens
/// closed tabs on the machine they were closed on. Observes structure only
/// (which tab is in which pane); a closed tab's cwd, URL, and terminal are
/// read from the last `TabModel` seen, which the store leaves untouched
/// after removal. Session-local browser tabs are not tracked. A terminal tab
/// reopened within its daemon's reap grace period shows the same live
/// terminal (`ClosedTerminalRestorer`). Record ids are qualified by machine
/// (`<machine>/<id>`) because daemon-local ids repeat across machines.
final class ClosedTabTracker {
    private unowned let services: AppServices
    /// Bumps after every change to the closed list or to the tabs it
    /// watches, once the list is up to date: observers (Search Tabs, the
    /// control snapshot) read the mirror and the closed list together.
    let changes = ClosedTabChanges()
    /// Replaces the daemon path for reopening terminal tabs (tests). Nil
    /// uses the owning machine's daemon (`ClosedTerminalRestorer.live`).
    var restorer: ClosedTerminalRestorer?
    private var history = ClosedTabHistory()
    private var lastSeen: [String: TabModel] = [:]
    private var generations: [String: String] = [:]
    /// Closed tabs that were in an incognito window (qualified tab ids):
    /// they reopen only in an incognito window, and normal ones only in a
    /// normal window.
    private var incognitoRecords: Set<String> = []
    private var observation: Task<Void, Never>?

    private struct Structure: Sendable {
        var tabs: [(tab: TabModel, record: ClosedTabHistory.Record)]
        var live: Set<String>
        /// Boot generation per connected machine.
        var generations: [String: String]
    }

    init(services: AppServices) {
        self.services = services
        let machines = services.machines
        observation = Task { [weak self] in
            for await structure in Observations({ Self.structure(of: machines.daemons) }) {
                self?.apply(structure)
            }
        }
    }

    deinit { observation?.cancel() }

    static func qualified(_ machine: String, _ id: String) -> String { "\(machine)/\(id)" }

    /// `(machine, id)` of a qualified record id.
    static func split(_ qualified: String) -> (machine: String, id: String)? {
        guard let slash = qualified.firstIndex(of: "/") else { return nil }
        return (String(qualified[..<slash]), String(qualified[qualified.index(after: slash)...]))
    }

    /// Connected machines only: a machine that drops takes its tabs and
    /// workspaces out together, so nothing on it counts as closed.
    private static func structure(of daemons: [DaemonService]) -> Structure {
        var tabs: [(TabModel, ClosedTabHistory.Record)] = []
        var live: Set<String> = []
        var generations: [String: String] = [:]
        for daemon in daemons {
            let store = daemon.store
            // The launch snapshot's provisional tree is not live: a tab it
            // shows that the live tree lacks was not closed in this app.
            guard case .connected = store.connectionState, store.isLoaded, !store.isProvisional else { continue }
            let machine = daemon.machineID
            generations[machine] = store.generation?.rawValue ?? ""
            for workspace in store.workspaces {
                live.insert(qualified(machine, workspace.id))
                for screen in workspace.screens {
                    for pane in screen.panes {
                        for (index, tab) in pane.tabs.enumerated() {
                            let kind: ClosedTabHistory.Record.Kind
                            switch tab.kind {
                            case .pty: kind = .terminal
                            case .browser: kind = .browser
                            default: continue
                            }
                            tabs.append((tab, ClosedTabHistory.Record(
                                kind: kind, tabID: qualified(machine, tab.id), paneID: qualified(machine, pane.id),
                                workspaceID: qualified(machine, workspace.id), index: index)))
                        }
                    }
                }
            }
        }
        return Structure(tabs: tabs, live: live, generations: generations)
    }

    private func apply(_ structure: Structure) {
        // A machine's daemon restarted (new boot generation): its tabs come
        // back with new ids, so forget the baseline instead of recording
        // every one of them as closed.
        let restarted = structure.generations.contains { machine, generation in
            generations[machine].map { $0 != generation } ?? false
        }
        generations = structure.generations
        if restarted { history.resetBaseline() }
        let previous = lastSeen
        history.observe(structure.tabs.map(\.record), liveWorkspaces: structure.live) { [weak self] record in
            var record = record
            if let workspace = Self.split(record.workspaceID)?.id, self?.services.windows.isIncognito(workspace: workspace) == true {
                self?.incognitoRecords.insert(record.tabID)
            }
            record.cwd = previous[record.tabID]?.cwd
            record.url = previous[record.tabID]?.url
            record.engine = previous[record.tabID]?.browserEngine
            record.terminalResourceID = previous[record.tabID]?.terminalResourceID?.rawValue
            record.title = previous[record.tabID].map(\.displayTitle).flatMap { $0.isEmpty ? nil : $0 }
            record.closedAt = Date()
            return record
        }
        lastSeen = Dictionary(structure.tabs.map { ($0.record.tabID, $0.tab) }, uniquingKeysWith: { first, _ in first })
        changes.bump()
    }

    func popLast() -> ClosedTabHistory.Record? {
        defer { changes.bump() }
        return history.popLast()
    }

    /// Closed tabs, oldest first (history lists).
    var records: [ClosedTabHistory.Record] { history.closed }

    /// Takes one record out to reopen it.
    func take(_ tabID: String) -> ClosedTabHistory.Record? {
        defer { changes.bump() }
        return history.remove(tabID: tabID)
    }

    func clear(since: Date?) {
        history.removeAll(since: since)
        changes.bump()
    }

    /// Reopens `record` at its old position in its old pane, else in `fallback`.
    func reopen(_ record: ClosedTabHistory.Record, fallback: PaneController?) {
        let owner = Self.split(record.paneID)
        let recorded = owner.flatMap { owner in
            services.machines.daemon(machine: owner.machine)?.store.workspaces
                .flatMap(\.screens).flatMap(\.panes).first { $0.id == owner.id }
        }
        let paneModel = recorded ?? fallback?.pane
        guard let paneModel else {
            services.registry.refuse(RefusalStrings.closedTabPaneGone)
            return
        }
        let target = services.workspaceID(of: paneModel).map { services.windows.isIncognito(workspace: $0) } ?? false
        guard target == incognitoRecords.contains(record.tabID) else {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return
        }
        let controller = services.paneController(for: paneModel)
        switch record.kind {
        case .browser:
            guard let controller else {
                services.registry.refuse(RefusalStrings.browserReopenNeedsWindow)
                return
            }
            // The engine its record named (WebKit with a notice when Chromium is missing).
            controller.newBrowserTab(url: record.url.flatMap(URL.init(string:)), inherited: record.engine)
        case .terminal:
            let daemon = services.daemon(for: paneModel)
            let restorer = restorer ?? .live(daemon)
            guard restorer.isAvailable() else {
                services.registry.refuse(MiscHandlerStrings.daemonOffline)
                return
            }
            let spawn = ClosedTerminalRestorer.Spawn(pane: paneModel.handle, cwd: record.cwd,
                                                     workspace: services.workspaceKey(of: paneModel), index: record.index)
            let path = services.resourcePath(of: paneModel)
            let logger = daemon.logger
            services.registry.track(Task { @MainActor in
                if let terminal = record.terminalResourceID, let path {
                    do {
                        let tab = try await restorer.project(ResourceID(rawValue: terminal), path, record.index)
                        controller?.pendingSelectTab = tab.rawValue
                        controller.map { $0.apply($0.snapshot()) }
                        return nil
                    } catch {
                        // Ended (reaped, exited, or closed): start a new shell there.
                        logger.info("reopen-closed-tab: terminal \(terminal, privacy: .public) is gone (\(String(describing: error), privacy: .public)); starting a new one")
                    }
                }
                do {
                    let surface = try await restorer.spawn(spawn)
                    controller?.pendingSelectSurface = surface
                    controller.map { $0.apply($0.snapshot()) }
                    controller?.workspace?.expectFocus(on: surface)
                    return nil
                } catch {
                    logger.error("reopen-closed-tab failed: \(String(describing: error), privacy: .public)")
                    return "reopen-closed-tab: \(error)"
                }
            })
        }
    }
}
