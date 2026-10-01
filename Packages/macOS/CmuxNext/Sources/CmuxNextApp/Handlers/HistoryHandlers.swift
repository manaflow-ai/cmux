import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextPalette
import Foundation

/// History actions (plans/cmux-next/history.md): Go Back / Forward / Last
/// on the location trail, the history page and palette pages, reopen,
/// resume, clear, and Undo Layout Change.
enum HistoryHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("focusHistoryBack", run: { _ in
            guard services.locationTrail.navigate(.back) else { throw ActionFailure(message: HistoryAppStrings.nothingBack) }
        })
        registry.bind("focusHistoryForward", run: { _ in
            guard services.locationTrail.navigate(.forward) else { throw ActionFailure(message: HistoryAppStrings.nothingForward) }
        })
        registry.bind("focusHistoryLast", run: { _ in
            guard services.locationTrail.navigate(.last) else { throw ActionFailure(message: HistoryAppStrings.nothingBack) }
        })
        let pages: [(ActionID, @MainActor (AppServices) -> PalettePageSpec)] = [
            ("recentlyFocused", HistoryPalettePages.locations),
            ("recentlyClosed", HistoryPalettePages.closed),
            ("history.search", HistoryPalettePages.search),
        ]
        for (id, make) in pages {
            services.palette.sources.actionPages[id] = { [weak services] in services.map(make) }
            guard id != "recentlyClosed" else { continue }
            registry.bind(id, run: { _ in services.palette.show(page: make(services), relativeTo: context.activeWindow?.window) })
        }
        bindRecentlyClosed(registry, context)
        services.palette.sources.actionPages["history.resumeAgentSession"] = { [weak services] in services.map(HistoryPalettePages.agents) }
        registry.bind("history.resumeAgentSession", run: { invocation in
            guard let id = invocation["session"]?.stringValue, !id.isEmpty else {
                services.palette.show(page: HistoryPalettePages.agents(services), relativeTo: context.activeWindow?.window)
                return
            }
            services.registry.track(Task { @MainActor in
                await services.history.agents.refresh()
                guard let session = services.history.agents.session(id: id) else { return ActionWorkFailure(HistoryAppStrings.noSession) }
                HistoryRestorer(services: services).resume(session)
                return nil
            })
        })
        for id: ActionID in ["history.show", "browserShowHistory"] {
            registry.bind(id, run: { _ in services.historyPage.open() })
        }
        registry.bind("history.reopen", run: { _ in HistoryRestorer(services: services).reopen(closedID: nil) })
        registry.bind("history.clear", run: { invocation in
            let range = invocation["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .hour
            let kind = invocation["kind"]?.stringValue.flatMap(HistoryEntry.Kind.init(rawValue:))
            services.history.clear(kinds: kind.map { [$0] } ?? [], range: range)
        })
        bindLayoutUndo(registry, context)
    }

    /// Recently Closed…: on a daemon that serves the closed history (state
    /// resources), reopens the item named by `closed`, else shows the
    /// daemons' closed items as a menu. Without it, the app's history
    /// palette lists what this app saw closed.
    private static func bindRecentlyClosed(_ registry: ActionRegistry, _ context: AppActionContext) {
        let services = context.services
        registry.bind("recentlyClosed", run: { invocation in
            guard DaemonClosedHistory.isServed(in: services) else {
                if let id = invocation["closed"]?.stringValue {
                    throw ActionFailure(message: RefusalStrings.noClosedItem(id))
                }
                services.palette.show(page: HistoryPalettePages.closed(services), relativeTo: context.activeWindow?.window)
                return
            }
            if let id = invocation["closed"]?.stringValue {
                guard let entry = DaemonClosedHistory.entry(id, in: services) else {
                    throw ActionFailure(message: RefusalStrings.noClosedItem(id))
                }
                return DaemonClosedHistory.reopen(entry, services: services)
            }
            let entries = DaemonClosedHistory.entries([.tab, .screen, .workspace], in: services)
            guard !entries.isEmpty else { throw ActionFailure(message: RefusalStrings.noRecentlyClosedItem) }
            guard let window = context.activeWindow?.window else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
            ClosedHistoryMenu.popUp(entries, in: window) { id in
                _ = registry.perform("recentlyClosed", invocation: ActionInvocation(arguments: ["closed": .string(id)]))
            }
        })
    }

    /// A layout undo the daemon asked to confirm (it closes panes): the
    /// next Undo Layout Change on the same screen revision confirms it.
    private final class PendingUndo { var revision: UInt64? }

    /// Undo Layout Change: the daemon's per-screen undo (`layout-undo-v1`).
    private static func bindLayoutUndo(_ registry: ActionRegistry, _ context: AppActionContext) {
        let pending = PendingUndo()
        registry.bind("layout.undo", run: { invocation in
            guard let pane = context.paneController(invocation) else { throw ActionFailure(message: HistoryAppStrings.noPane) }
            let daemon = context.services.daemon(for: pane.pane)
            guard daemon.supports("layout-undo-v1") else { throw ActionFailure.needsDaemonCapability("layout-undo-v1") }
            guard let connection = daemon.connection else { throw ActionFailure(message: HistoryAppStrings.machineOffline) }
            let handle = pane.pane.handle
            let confirming = pending.revision
            pending.revision = nil
            context.services.registry.track(Task { @MainActor in
                do {
                    let response = try await connection.undoLayout(pane: handle, confirmingRevision: confirming)
                    guard response.confirmationRequired == true else { return nil }
                    pending.revision = response.revision
                    return ActionWorkFailure(HistoryAppStrings.undoClosesPanes(response.closesPanes?.count ?? 1))
                } catch {
                    return ActionWorkFailure("undo-layout", error)
                }
            })
        })
    }
}
