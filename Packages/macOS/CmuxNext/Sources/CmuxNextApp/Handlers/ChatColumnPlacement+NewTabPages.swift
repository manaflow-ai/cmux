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
        await followNewTabPages(pages, start: generation, generation: { content.focus.currentState().generation }, isDockCurrent: {
            services.locateTab(chat.id)?.1 === dock
                && content.workspace.screens.contains { $0.panes.contains { $0 === dock } }
                && ChatDockRules.isChatDock(dock, in: daemon.store)
        }, seed: {
            // The dock is new and no page is in it yet: the chat is its selected tab, so the
            // daemon's active-tab default never shows a page that follows it.
            content.state.selection.select(chat.id, in: dock.id)
        }, prepare: {
            // Focus only for the run's own intent: a newer click or key (FocusCoordinator's
            // generation) keeps the focus the person chose.
            whenDocked(dock)
        }, isChosen: { page in
            content.state.selection.selection(in: source.id) == page.id
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

    /// The order of a dock's follow-up: `seed` the new dock's selection (always: nothing newer can
    /// be in a dock that just appeared), `prepare` focus while the run's own intent is current, then
    /// move each page after the chat, rechecking the dock between awaits. A page the person selected
    /// after the run began stays where they are working. A failed move leaves its slot to the next.
    /// `start` is the focus generation when the run began; `prepare`'s own focus change moves it on,
    /// so the generation after `prepare` is the run's, and only a later one is the person's.
    @MainActor static func followNewTabPages<Page>(_ pages: [Page], start: UInt64, generation: @MainActor () -> UInt64,
                                                   isDockCurrent: @MainActor () -> Bool, seed: @MainActor () -> Void,
                                                   prepare: @MainActor () -> Void, isChosen: @MainActor (Page) -> Bool,
                                                   move: @MainActor (Page, Int) async -> Bool) async {
        guard isDockCurrent() else { return }
        seed()
        var expected = start
        if generation() == expected {
            prepare()
            expected = generation()
        }
        var index = 1
        for page in pages {
            guard isDockCurrent() else { return }
            if generation() != expected, isChosen(page) { continue }
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
