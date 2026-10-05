import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Recently closed tabs, screens, and workspaces as the daemon records them
/// (`closed-history-v1`, state-ownership.md 2). One shared path for Reopen
/// Closed Tab, Reopen Closed Screen, and Recently Closed: read the newest
/// item from the mirrored history (`DaemonStore.closedItems`), reopen it
/// with `closed.reopen`, and show what came back. The history lists
/// (Recently Closed…, `history.list`, the history page) show these items
/// beside the app's own trackers (`ClosedTabTracker`, `ClosedScreenHistory`),
/// which skip daemons that serve the history.
@MainActor
enum DaemonClosedHistory {
    struct Entry {
        var item: ClosedItem
        var daemon: DaemonService
    }

    /// Every connected daemon's closed items of `kinds`, newest first.
    static func entries(_ kinds: Set<ClosedItem.Kind>, in services: AppServices) -> [Entry] {
        services.machines.daemons.filter(\.store.servesStateResources).flatMap { daemon in
            daemon.store.closedItems.filter { kinds.contains($0.kind) }.map { Entry(item: $0, daemon: daemon) }
        }.sorted { $0.item.closedAtMs > $1.item.closedAtMs }
    }

    /// The id a history list gives a daemon-recorded item (`HistoryService`).
    static func historyID(_ id: String) -> String { "daemon:" + id }

    /// The daemon item id of a history list id, nil for the app's trackers.
    static func daemonID(fromHistoryID id: String) -> String? {
        id.hasPrefix("daemon:") ? String(id.dropFirst("daemon:".count)) : nil
    }

    /// True when some connected daemon records closed history.
    static func isServed(in services: AppServices) -> Bool {
        services.machines.daemons.contains { $0.store.servesStateResources }
    }

    /// The entry with id `id` on any daemon.
    static func entry(_ id: String, in services: AppServices) -> Entry? {
        entries([.tab, .screen, .workspace], in: services).first { $0.item.id == id }
    }

    /// Reopens `entry` on its daemon and shows it: a tab selected in its
    /// pane, a screen selected in its workspace, a workspace in the active
    /// window. The failure (if any) is the tracked work's result.
    static func reopen(_ entry: Entry, services: AppServices) {
        let daemon = entry.daemon, item = entry.item
        let pane = item.paneID.flatMap { id in
            daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.resourceID == id }
        }
        services.registry.track(Task { @MainActor in
            guard let connection = daemon.connection else { return ActionWorkFailure(MiscHandlerStrings.daemonOffline) }
            let reopened: StateResourceClient.ReopenedItem
            do {
                reopened = try await connection.state.reopenClosed(item.id)
            } catch {
                daemon.logger.error("closed.reopen failed: \(String(describing: error), privacy: .public)")
                return "closed.reopen: \(error)"
            }
            if item.kind == .tab, let tab = reopened.tabIDs.first, let pane, let controller = services.paneController(for: pane) {
                controller.selectWhenReported(tab: tab.rawValue)
                return nil
            }
            await daemon.store.applied(through: await connection.eventSequence())
            show(reopened, kind: item.kind, daemon: daemon, services: services)
            return nil
        })
    }

    /// Shows a reopened item once the store has it.
    private static func show(_ reopened: StateResourceClient.ReopenedItem, kind: ClosedItem.Kind, daemon: DaemonService,
                             services: AppServices) {
        guard let workspace = daemon.store.workspace(resourceID: reopened.workspaceID),
              let window = services.windows.active else { return }
        services.windows.show(workspaceID: workspace.id, in: window.state)
        switch kind {
        case .screen:
            guard let screen = workspace.screens.first(where: { $0.resourceID == reopened.screenIDs.first }),
                  let content = window.content else { return }
            ScreenCommands.select(LayoutScreenID(screen.id), in: content)
        case .tab:
            guard let tab = reopened.tabIDs.first,
                  let pane = workspace.screens.flatMap(\.panes).first(where: { $0.tabs.contains { $0.resourceID == tab } }),
                  let controller = services.paneController(for: pane) else { return }
            controller.selectWhenReported(tab: tab.rawValue)
        case .workspace:
            break
        }
    }
}
