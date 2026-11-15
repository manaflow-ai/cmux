import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextPalette
import CmuxNextWindowRules
import Foundation

/// History actions (plans/cmux-next/history.md): Go Back / Forward / Last
/// on the location trail, the history page and palette pages, reopen,
/// resume, clear, and Undo Layout Change.
enum HistoryHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // `history::actions`. Nowhere to go is refused quietly (R136): callers get the reason, a key press shows nothing.
        let table = WindowRules().historyActions()
        for walk in table?.walks ?? [] {
            let (direction, nowhere): (LocationTrailService.Direction, @MainActor () -> String) = switch walk.direction {
            case "forward": (.forward, { HistoryAppStrings.nothingForward })
            case "last": (.last, { HistoryAppStrings.nothingLast })
            default: (.back, { HistoryAppStrings.nothingBack })
            }
            registry.bind(ActionID(rawValue: walk.action), run: { _ in
                guard services.locationTrail.navigate(direction) else { throw ActionFailure.noTarget(nowhere()) }
            })
        }
        // A row of the Back / Forward button list (history.md 4.2a): the trail index it shows.
        registry.bind("history.goTo", run: { invocation in
            guard let index = invocation["index"]?.intValue, services.locationTrail.go(toIndex: index) else {
                throw ActionFailure(message: HistoryAppStrings.entryGone)
            }
        })
        for page in table?.pages ?? [] {
            let make: @MainActor (AppServices) -> PalettePageSpec = switch page.page {
            case "closed": HistoryPalettePages.closed
            case "search": HistoryPalettePages.search
            case "commands": HistoryPalettePages.commands
            default: HistoryPalettePages.locations
            }
            let id = ActionID(rawValue: page.action)
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
        for id in table?.historyPage ?? [] {
            registry.bind(ActionID(rawValue: id), run: { _ in services.historyPage.open() })
        }
        registry.bind("agentHistory.show", run: { invocation in context.paneController(invocation).map { AgentHistoryPage.open(in: $0) } })
        registry.bind("history.reopen", run: { invocation in
            HistoryRestorer(services: services).reopen(closedID: invocation["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        })
        // One entry's restore action by id (the History page's rows, `cmux history open`). The
        // entry is looked up from its owners, so a caller names it and never supplies its facts.
        registry.bind("history.open", run: { invocation in
            guard let id = invocation["id"]?.stringValue, !id.isEmpty else { return }
            let newTab = invocation["newTab"]?.boolValue ?? false
            services.registry.track(Task { @MainActor in
                switch await services.history.lookup(id: id).opening {
                case .success(let entry):
                    HistoryRestorer(services: services).open(entry, newTab: newTab)
                    return nil
                case .failure(let refusal):
                    return refusal
                }
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
            guard daemon.supports("layout-undo-v1") else { throw ActionFailure(message: daemon.missingCapabilityMessage("layout-undo-v1")) }
            guard let connection = daemon.connection else { throw ActionFailure(message: HistoryAppStrings.machineOffline) }
            let handle = pane.pane.handle
            let confirming = pending.revision
            pending.revision = nil
            context.services.registry.track(Task { @MainActor in
                do {
                    let response = try await connection.undoLayout(pane: handle, confirmingRevision: confirming)
                    let reply = WindowRules().undoReply(confirmationRequired: response.confirmationRequired == true, revision: response.revision,
                                                        closesPanes: response.closesPanes?.count)
                    pending.revision = reply?.pending
                    return reply?.closesPanes.map { ActionWorkFailure(HistoryAppStrings.undoClosesPanes($0)) }
                } catch {
                    return ActionWorkFailure("undo-layout", error)
                }
            })
        })
    }
}

extension HistoryLookup {
    /// The entry `history.open` opens, or why it opens none.
    @MainActor var opening: Result<HistoryEntry, ActionWorkFailure> {
        switch self {
        case .found(let entry) where entry.isAvailable: .success(entry)
        case .stillLoading: .failure(ActionWorkFailure(refusal: .unavailable, reason: HistoryAppStrings.stillLoading))
        case .found, .gone: .failure(ActionWorkFailure(HistoryAppStrings.entryGone))
        }
    }
}
