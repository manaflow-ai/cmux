import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextWakeups
import Foundation
import Observation

/// New ▸ Kind ▸ Placement (`new.<kind>.<place>`): one function opens a Terminal, a Browser, an
/// Agent Chat or a New Tab Page at any of Fork To's ten places, from the pane's New menu, its •••
/// menu, the palette and `cmux pane new-…`. The plan is the layout reducer's (``NewPlacementPlan``):
/// a kind whose own create makes it there in one daemon commit runs that create (Cmd-D's split,
/// New Column, Split Browser, a split's New Tab Page or chat), which shows its pane through the
/// one split transition (`showSplitSizing`, then the daemon, then commit or cancel); any other is
/// made unselected in the pane and out of its strip, then moved there in one daemon move, as a
/// link's tab or a fork is (`TabMoves`, `DaemonService.placeFork`, Move Tab to New Workspace / Window).
enum NewAtPlacement {
    /// How long a move waits for the new tab to be listed, then to leave its pane.
    static let listLimit: Duration = .seconds(30)

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        for id in ActionID.newPlacementActions {
            guard let (kind, place) = id.newPlacement else { continue }
            // A new row needs rows on and `rows-v1`; Cmd-D's terminal column on the left needs
            // `column-left-v1` (the moves place a column on the left without it, as a fork's does).
            let unavailable: @MainActor () -> String? = switch (kind, place) {
            case (_, "row"): { ColumnHandlers.newRowUnavailableReason(ctx) }
            case ("terminal", "columnLeft"): { ColumnHandlers.newColumnLeftUnavailableReason(ctx) }
            default: { nil }
            }
            _ = registry.bindEffect(id, unavailable: unavailable, effect: { invocation in
                open(kind, at: place, invocation, ctx)
            })
        }
        // A kind's submenu row: `cmux action run new.<kind>` opens it on the right, Fork To's default.
        for submenu in ActionID.newPlacementSubmenus {
            let kind = String(submenu.rawValue.dropFirst("new.".count))
            _ = registry.bindEffect(submenu, effect: { open(kind, at: "right", $0, ctx) })
        }
    }

    /// Opens `kind` at `place` from the invocation's pane (the focused one when it names none).
    @MainActor static func open(_ kind: String, at place: String, _ invocation: ActionInvocation, _ ctx: AppActionContext) -> ActionEffect {
        guard let pane = ctx.paneController(invocation) else { return .refused(MiscHandlerStrings.noPane) }
        let tabSplit = pane.daemon.supports(DaemonCapability.conversationTabSplit.rawValue)
        // An app FFI from before `new_placement` answers nothing: the item is made and moved, which reaches every place.
        guard let plan = NewPlacementPlan(kind: kind, place: place, tabSplit: tabSplit) ?? NewPlacementPlan.fallback(place: place) else {
            return .done
        }
        var aimed = invocation.onMachine(pane.daemon.machineID)
        aimed.target = ActionTargetRef(kind: .pane, id: pane.paneKey)
        // A browser the CLI, MCP or a script opens is an agent's: no saved password fills in it
        // (TabLifecycle.newBrowser, plans/cmux-next/browser.md). Split Browser does not mark its tab, so an
        // automated browser is always made here, marked before its first load, then moved.
        // A pane whose daemon does not make browser tabs makes a session-local one, which no daemon move can
        // take and which reports no surface: such a browser opens only in a new tab here.
        if kind == "browser", plan.op != .tab, !pane.daemon.supports(DaemonCapability.frontendBrowserTabs.rawValue) {
            return .refused(RefusalStrings.needsDaemonCapability(DaemonCapability.frontendBrowserTabs.rawValue))
        }
        let route = Self.route(kind, plan, origin: invocation.origin)
        if route.ownCreate, inPlace(kind, plan.op, pane: pane, aimed, ctx) { return .done }
        madeThenMoved(kind, plan.op, from: pane, agentDriven: route.agentDriven, ctx)
        return .done
    }

    /// How `kind` reaches `plan`'s place for a run from `origin`: by the kind's own create, or made here and
    /// moved, and whether the tab made here is marked agent-driven before its first load. A browser from the
    /// CLI, MCP or a script is agent-driven; its own create at a new tab (openBrowser) marks it, Split Browser does not.
    nonisolated static func route(_ kind: String, _ plan: NewPlacementPlan, origin: ActionOrigin) -> (ownCreate: Bool, agentDriven: Bool) {
        let agentDriven = kind == "browser" && [.cli, .mcp, .script].contains(origin)
        return (plan.madeInPlace && !(agentDriven && plan.op != .tab), agentDriven)
    }

    /// The kind's own create at `op`, in one daemon commit. False when the kind has none there.
    @MainActor static func inPlace(_ kind: String, _ op: NewPlacementPlan.Op, pane: PaneController, _ aimed: ActionInvocation,
                                   _ ctx: AppActionContext) -> Bool {
        let registry = ctx.registry
        switch (kind, op) {
        case ("terminal", .split(let edge)):
            // Cmd-D's split, a terminal even beside a page or a chat (where a person's split opens the New Tab page).
            var terminal = aimed
            terminal.opensTerminal = true
            PaneHandlers.split(ctx, terminal, direction: direction(edge))
            return true
        case ("terminal", .column(let left)): return registry.perform(left ? "newColumnLeft" : "newColumn", invocation: aimed)
        case ("terminal", .row): return registry.perform("newRow", invocation: aimed)
        case ("terminal", .tab):
            // In this pane, as asked: newSurface would follow `newTerminal.opensWorkspace`.
            pane.newTerminalTab(fromSelectedTab: true)
            return true
        case ("browser", .split(edge: "right")): return registry.perform("splitBrowserRight", invocation: aimed)
        case ("browser", .split(edge: "bottom")): return registry.perform("splitBrowserDown", invocation: aimed)
        case ("browser", .tab): return registry.perform("openBrowser", invocation: aimed)
        case ("newTabPage", .split(let edge)):
            // Left and above split right or below, then swap back, as Split Left does.
            return NewTabPage.split(pane, edge: edge == "left" || edge == "right" ? .right : .bottom, swapsBack: edge == "left" || edge == "top")
        case ("newTabPage", .tab):
            pane.newTabPage()
            return true
        case ("agentChat", .tab):
            // In this pane, whatever the chat dock would do with a New Agent Chat.
            return pane.services.agentTabs.openTab(in: pane, seed: pane.agentSeedFromSelectedTab())
        case ("agentChat", .split(let edge)) where edge == "right" || edge == "bottom":
            return chatInSplit(pane, direction: edge == "right" ? .right : .down)
        default:
            return false
        }
    }

    /// A new chat made in its own split (`conversation-tab-split-v1`), its pane and the chain's even
    /// sizing shown in this frame and committed with the daemon's answer, as a split's New Tab Page is.
    @MainActor private static func chatInSplit(_ pane: PaneController, direction: SplitDirection) -> Bool {
        let layout = pane.workspace?.layoutModel
        let sizing = layout?.splitSizingChanges(splitting: pane.layoutPaneID, axis: direction == .right ? .horizontal : .vertical) ?? []
        let shown = layout?.showSplitSizing(sizing)
        let cancel = { if let shown { layout?.cancelSplitSizing(shown) } }
        let started = pane.services.agentTabs.openTab(in: pane, seed: pane.agentSeedFromSelectedTab(), select: false, split: direction,
                                                      then: { _ in if let shown { layout?.commitSplitSizing(shown) } }, failed: { cancel() })
        guard started else {
            cancel()
            return true // refused with its reason (AgentTabStore.openTab)
        }
        BenchSpans.measure("split.layout") { pane.workspace?.applyCurrent() }
        return true
    }

    /// `kind` made unselected in `pane` and kept out of its strip, then moved to `op`'s place.
    @MainActor static func madeThenMoved(_ kind: String, _ op: NewPlacementPlan.Op, from pane: PaneController, agentDriven: Bool = false,
                                         _ ctx: AppActionContext) {
        let services = pane.services, store = pane.daemon.store, machineID = pane.daemon.machineID
        switch kind {
        case "terminal", "browser":
            let outbound = OutboundTab.begin(in: pane)
            let cache = services.cache
            let placed: @MainActor (SurfaceID) -> Void = { surface in
                // Before the page exists: its first load fills no saved password (TabContentCache.markAgentDriven).
                if kind == "browser", agentDriven { cache.markAgentDriven(surface: surface) }
                outbound.made(surface)
                place({ store.tab(surface: surface).flatMap { services.locateTab(model: $0) } }, from: pane, op, ctx) { outbound.finish(moved: $0) }
            }
            let made: Bool
            if kind == "terminal" {
                // The selected tab's folder, without `fromSelectedTab`: from another machine's terminal that opens
                // a terminal there, which never reports its surface here, so the move could not run.
                let cwd = NewTerminalStart.inherited(besides: pane.selectedTab, in: pane.pane, services: services) ?? pane.selectedTab?.cwd
                pane.newTerminalTab(cwd: cwd, placementOwner: true, then: placed)
                made = true
            } else {
                made = pane.newBrowserTab(background: true, placementOwner: true, then: placed)
            }
            _ = outbound.started(made) // a refused open finishes the outbound hold itself
        case "agentChat":
            _ = services.agentTabs.openTab(in: pane, seed: pane.agentSeedFromSelectedTab(), select: false, hidden: true) { [weak pane] key in
                guard let pane else { return }
                place({ services.locateTab(key, onMachine: machineID) }, from: pane, op, ctx) { [weak pane] _ in pane?.dockFinished(key) }
            }
        case "newTabPage":
            // The page shows only after its move: it takes no held keys (focusesPage false); the move focuses it.
            NewTabPage.split(pane, edge: .right, focusesPage: false, placed: { [weak pane] key in
                guard let pane else { return }
                place({ services.locateTab(key, onMachine: machineID) }, from: pane, op, ctx) { [weak pane] _ in pane?.dockFinished(key) }
            })
        default:
            break
        }
    }

    /// Moves the new tab `locate` finds, once the store lists it, to `op`'s place, then focuses it.
    /// `finished` gets whether it left its pane (the source's strip may list it again either way).
    @MainActor static func place(_ locate: @escaping @MainActor () -> (TabModel, PaneModel)?, from source: PaneController,
                                 _ op: NewPlacementPlan.Op, _ ctx: AppActionContext, finished: @escaping @MainActor (Bool) -> Void) {
        let services = source.services, registry = ctx.registry, store = source.daemon.store
        // A new tab is listed and a moved one leaves its pane with the store's tab-list revision (its
        // surface index is not observed): every wait reads it, as LinkOpener's do.
        let listed = { @MainActor in _ = store.tabListRevision; return locate() }
        let outcome = MoveOutcome()
        let rowHeight = source.workspace?.layoutModel.newRowHeight(below: source.layoutPaneID) ?? 1000
        // main-hop-allow: the action's effect already ran in its turn (the tab is made); this tracked work only waits
        // for the store to list the tab and then sends one daemon move, as NewTabPage.moveToSplit does. Each wakeup is
        // one locateTab lookup, and both waits end at `listLimit` (DemandTimer).
        services.registry.track(Task { @MainActor () -> ActionWorkFailure? in
            guard await within(listLimit, { listed() != nil }), case let (tab, home)? = listed() else {
                finished(false)
                return "new: the new tab did not open"
            }
            let target = ActionTargetRef(kind: .tab, id: tab.id)
            // Tab ids repeat across machines: every run names the tab's machine.
            let onTab = ActionInvocation(target: target, origin: .user).onMachine(services.daemon(for: home).machineID)
            // A refused move ends the wait at once: the tab shows again in its pane now, not at the limit.
            let done: @MainActor (Bool) -> Void = { moved in if !moved { outcome.refused = true } }
            switch op {
            case .split(let edge):
                TabMoves.toNewSplit(tab, pane: home, edge: PaneEdge(rawValue: edge) ?? .right, services: services, completion: done)
            case .column(let left):
                services.daemon(for: home).placeFork(tab.surface, beside: home, left: left, rowHeight: rowHeight) { column, moved in
                    TabMoves.toNewColumn(tab, anchor: home, afterColumn: column, services: services) { done($0); moved($0) }
                }
            case .row:
                services.daemon(for: home).placeFork(tab.surface, beside: home, left: nil, rowHeight: rowHeight, rowRefused: { done(false) }) { column, moved in
                    TabMoves.toNewColumn(tab, anchor: home, afterColumn: column, services: services) { done($0); moved($0) }
                }
            case .workspace:
                done(registry.perform("palette.moveTabToNewWorkspace", invocation: onTab))
            case .window:
                done(registry.perform("tab.moveToNewWindow", invocation: onTab))
            case .tab:
                finished(true)
                return nil
            }
            let machineID = services.daemon(for: home).machineID
            let left = { @MainActor in _ = store.tabListRevision; return services.locateTab(tab.id, onMachine: machineID).map { $0.1 !== home } ?? false }
            _ = await within(listLimit) { outcome.refused || left() }
            let moved = left()
            finished(moved)
            guard moved else { return "new: the move to its place failed (see the app log)" }
            // The tab was made unselected and its move does not focus it: focus it where it landed.
            _ = registry.perform("tab.focus", invocation: onTab)
            return nil
        })
    }

    /// A move's refusal, which ends its wait (observed).
    @Observable @MainActor final class MoveOutcome {
        var refused = false
    }

    /// Whether `holds` turns true within `limit`, read now and on every change it observes.
    @MainActor private static func within(_ limit: Duration, _ holds: @escaping @MainActor () -> Bool) async -> Bool {
        if holds() { return true }
        // main-hop-allow: an ObservationStream read of `holds` (one store lookup) per change, cancelled at `limit`.
        let found = Task { @MainActor () -> Bool in
            for await now in ObservationStream({ holds() }) where now { return true }
            return false
        }
        let bound = DemandTimer(owner: "NewAtPlacement.within")
        bound.schedule(after: limit) { @MainActor in found.cancel() }
        let value = await found.value
        bound.cancel()
        return value
    }

    static func direction(_ edge: String) -> PaneDirection {
        switch edge {
        case "left": .left
        case "top": .up
        case "bottom": .down
        default: .right
        }
    }
}
