import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWakeups

extension ChatColumnPlacement {
    /// The New Tab pages that follow a docking chat, in their original relative order.
    nonisolated static func newTabPages<Tab>(in tabs: [Tab], isNewTabPage: (Tab) -> Bool) -> [Tab] {
        tabs.filter(isNewTabPage)
    }

    /// Joins the chat's new dock after its move is reported. The caller awaits this inside its
    /// tracked run; optional page moves cannot fail the tool open or move keyboard focus.
    @MainActor static func moveNewTabPages(_ pages: [TabModel], with chat: TabModel, from source: PaneModel,
                                           in content: WorkspaceContentController, services: AppServices,
                                           generation: UInt64, whenDocked: @MainActor (PaneModel) -> Void = { _ in }) async {
        let daemon = services.machines.daemon(forTab: chat)
        let appeared = await waitForDockUpdate {
            services.locateTab(chat.id).map { $0.1 !== source } ?? false
        }
        guard appeared, let dock = services.locateTab(chat.id)?.1 else {
            daemon.logger.error("chat dock: the moved chat's pane did not appear; New Tab pages stayed in their pane")
            return
        }
        await followNewTabPages(pages, focus: content.focus, generation: generation, isDockCurrent: {
            services.locateTab(chat.id)?.1 === dock
                && content.workspace.screens.contains { $0.panes.contains { $0 === dock } }
                && ChatDockRules.isChatDock(dock, in: daemon.store)
        }, prepare: {
            // Only the run's original intent may seed selection or restore focus. Newer
            // keyboard/mouse selections bump this existing FocusCoordinator generation.
            content.state.selection.select(chat.id, in: dock.id)
            whenDocked(dock)
        }) { page, index in
            guard services.locateTab(page.id)?.1 === source,
                  services.agentTabs.isNewTabPage(page.id) else { return false }
            let transaction = ClientTransactionID.generate()
            // The enclosing tracked task still awaits these moves. Their daemon errors are
            // logged, but must not become failures of the tool's action.run command scope.
            // The move issues its daemon command synchronously, so the binding only has to cover the call.
            let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DaemonCommandScope.$current.withValueInTask(nil) {
                    TabMoves.move(page, to: dock, index: index, services: services, transaction: transaction) { done.resume(returning: $0) }
                }
            }
            guard moved else {
                daemon.logger.error("chat dock: a New Tab page could not follow the chat; leaving it in its pane")
                return false
            }
            // A move's optimistic intent is visible before its echo. Wait for settlement too,
            // so the run answers with the final layout, rather than a pending move overlay.
            let (applied, sink) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            daemon.whenApplied(transaction) {
                sink.yield(true)
                sink.finish()
            }
            let bound = DemandTimer(owner: "ChatColumnPlacement.newTabMove")
            bound.schedule(after: AgentBesidePlacement.openLimit) { @MainActor in sink.finish() }
            var echo = applied.makeAsyncIterator()
            let settled = await echo.next() == true
            bound.cancel()
            guard settled, services.locateTab(page.id)?.1 === dock else {
                daemon.logger.error("chat dock: a New Tab page's move was not reported in the dock")
                return false
            }
            return true
        }
    }

    /// Prepares selection before any optional moves, revalidating the destination between awaits.
    /// A failed move leaves its slot available to the next page and never fails the tool open.
    @MainActor static func followNewTabPages<Page>(_ pages: [Page], focus: FocusCoordinator, generation: UInt64, isDockCurrent: @MainActor () -> Bool,
                                                   prepare: @MainActor () -> Void, move: @MainActor (Page, Int) async -> Bool) async {
        guard isDockCurrent() else { return }
        if focus.currentState().generation == generation { prepare() }
        var index = 1
        for page in pages {
            guard isDockCurrent() else { return }
            if await move(page, index) { index += 1 }
        }
    }

    /// A bounded event-driven wait, using the same deadline as the beside-caller placement.
    @MainActor private static func waitForDockUpdate(_ ready: @escaping @MainActor () -> Bool) async -> Bool {
        let listed = Task { @MainActor in
            for await found in ObservationStream(ready) where found { return true }
            return false
        }
        let bound = DemandTimer(owner: "ChatColumnPlacement.newTabPages")
        bound.schedule(after: AgentBesidePlacement.openLimit) { @MainActor in listed.cancel() }
        let found = await listed.value
        bound.cancel()
        return found
    }
}
