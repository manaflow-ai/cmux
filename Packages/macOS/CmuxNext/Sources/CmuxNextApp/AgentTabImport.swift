import CmuxNextDaemon
import Foundation
import Observation

/// One-time import of the agent tabs an older build recorded in the window document
/// (`WindowStateDocument.legacyAgentTabs`, R138) into the workspace store. Each recorded tab with
/// a session becomes a store tab in its pane under the key `agent-tab-import-<old id>`, so a crash
/// mid-import replays instead of duplicating. Windows that selected an old tab select its store
/// tab, in the document and on screen. One compare-and-swap write keeps only the records that
/// could not be imported yet: the pane's daemon lacks agent session tabs or refused the tab, or no
/// tree lists the pane while some machine's tree is not live. Records without a session and
/// records of panes gone from every live tree are dropped.
@MainActor
enum AgentTabImport {
    /// The idempotency key of the store tab imported for old tab `id`.
    static func key(for id: String) -> String { "agent-tab-import-" + id }

    /// Imports once the local daemon's tree has loaded.
    static func start(_ services: AppServices) {
        // The window state store exists only once the daemon connects, which
        // is after launch (DaemonService sets it before the store loads), so
        // it is read when the tree has loaded: read at launch it was nil and
        // the import never ran.
        let store = services.daemon.store
        // task-owner: one-shot, ends after the first load
        Task {
            for await loaded in Observations({ store.isLoaded }) where loaded {
                guard let windowState = services.daemon.windowState else { return }
                await run(services, windowState: windowState)
                return
            }
        }
    }

    static func run(_ services: AppServices, windowState: WindowStateStore) async {
        guard let document = try? await windowState.load(), !document.legacyAgentTabs.isEmpty else { return }
        // A pane no tree lists is dropped only when every machine's tree is live, so a remote
        // machine that has not loaded yet keeps its records for the next launch.
        let everyTreeLive = services.machines.daemons.allSatisfy { AgentTabStore.liveTabs($0.store) != nil }
        var renamed: [String: String] = [:]
        var remaining: [String: [AgentTabRecord]] = [:]
        for (paneKey, records) in document.legacyAgentTabs {
            guard let pane = services.pane(id: paneKey) else {
                if !everyTreeLive { remaining[paneKey] = records }
                continue
            }
            let daemon = services.daemon(for: pane)
            guard services.agentTabs.holdsTabs(daemon) else {
                remaining[paneKey] = records // its daemon cannot hold them yet
                continue
            }
            for record in records {
                guard let session = record.session else { continue } // an empty new chat is not restored
                do {
                    let created = try await services.agentTabs.open(in: pane.handle, of: daemon, session: session,
                                                                    idempotencyKey: key(for: record.id)).value()
                    renamed[record.id] = created.key
                    // Windows restored before the import showed the old tab: they show the store tab.
                    for controller in services.windows.controllers where controller.state.selection.selection(in: pane.id) == record.id {
                        controller.state.selection.select(created.key, in: pane.id)
                    }
                } catch {
                    services.daemon.logger.error("agent tab import: \(String(describing: error), privacy: .public)")
                    remaining[paneKey, default: []].append(record)
                }
            }
        }
        let imported = renamed
        let left = remaining
        _ = try? await windowState.update { document in finish(&document, imported: imported, remaining: left) }
    }

    /// The import's document write: only `remaining` records stay, and every window that selected
    /// an imported old tab selects its store tab.
    nonisolated static func finish(_ document: inout WindowStateDocument, imported: [String: String],
                                   remaining: [String: [AgentTabRecord]]) {
        document.legacyAgentTabs = remaining
        for index in document.windows.indices {
            for (pane, tab) in document.windows[index].selectedTabs {
                if let new = imported[tab] { document.windows[index].selectedTabs[pane] = new }
            }
        }
    }
}
