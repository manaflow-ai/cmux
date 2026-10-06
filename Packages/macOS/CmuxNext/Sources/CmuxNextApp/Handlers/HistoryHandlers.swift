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
            _ = services.locationTrail.navigate(.back)
        })
        registry.bind("focusHistoryForward", run: { _ in
            _ = services.locationTrail.navigate(.forward)
        })
        registry.bind("focusHistoryLast", run: { _ in
            _ = services.locationTrail.navigate(.last)
        })
        // A row of the Back / Forward button list (history.md 4.2a): the trail index it shows.
        registry.bind("history.goTo", run: { invocation in
            guard let index = invocation["index"]?.intValue, services.locationTrail.go(toIndex: index) else {
                throw ActionFailure(message: HistoryAppStrings.entryGone)
            }
        })
        let pages: [(ActionID, @MainActor (AppServices) -> PalettePageSpec)] = [
            ("recentlyFocused", HistoryPalettePages.locations),
            ("recentlyClosed", HistoryPalettePages.closed),
            ("history.search", HistoryPalettePages.search),
            ("history.commands", HistoryPalettePages.commands),
        ]
        for (id, make) in pages {
            services.palette.sources.actionPages[id] = { [weak services] in services.map(make) }
            registry.bind(id, run: { _ in services.palette.show(page: make(services), relativeTo: context.activeWindow?.window) })
        }
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
        registry.bind("history.reopen", run: { invocation in
            HistoryRestorer(services: services).reopen(closedID: invocation["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        })
        // One entry's restore action by id (the History page's rows, `cmux history open`). The
        // entry is looked up from its owners, so a caller names it and never supplies its facts.
        registry.bind("history.open", run: { invocation in
            guard let id = invocation["id"]?.stringValue, !id.isEmpty else { return }
            let newTab = invocation["new_tab"]?.boolValue ?? false
            services.registry.track(Task { @MainActor in
                guard let entry = await services.history.entry(id: id), entry.isAvailable else {
                    return ActionWorkFailure(HistoryAppStrings.entryGone)
                }
                HistoryRestorer(services: services).open(entry, newTab: newTab)
                return nil
            })
        })
        registry.bind("history.clear", run: { invocation in
            let range = invocation["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .hour
            let kind = invocation["kind"]?.stringValue.flatMap(HistoryEntry.Kind.init(rawValue:))
            services.history.clear(kinds: kind.map { [$0] } ?? [], range: range)
        })
        bindLayoutUndo(registry, context)
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
