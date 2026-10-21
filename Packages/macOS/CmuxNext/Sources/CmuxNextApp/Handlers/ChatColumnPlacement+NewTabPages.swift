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
                                           whenDocked: @MainActor (PaneModel) -> Void = { _ in }) async {
        let daemon = services.machines.daemon(forTab: chat)
        let appeared = await waitForDockUpdate {
            services.locateTab(chat.id).map { $0.1 !== source } ?? false
        }
        guard appeared, let dock = services.locateTab(chat.id)?.1 else {
            daemon.logger.error("chat dock: the moved chat's pane did not appear; New Tab pages stayed in their pane")
            return
        }
        // Seed the window's selection before the first page arrives, even if its new pane's
        // controller has not mounted yet. Daemon active-tab defaults must not select a page.
        content.state.selection.select(chat.id, in: dock.id)
        whenDocked(dock)
        var index = 1
        for page in pages {
            guard services.locateTab(page.id)?.1 === source,
                  services.agentTabs.isNewTabPage(page.id) else { continue }
            let transaction = ClientTransactionID.generate()
            // The enclosing tracked task still awaits these moves. Their daemon errors are
            // logged, but must not become failures of the tool's action.run command scope.
            let moved = await DaemonCommandScope.$current.withValue(nil) {
                await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    TabMoves.move(page, to: dock, index: index, services: services, transaction: transaction) { done.resume(returning: $0) }
                }
            }
            guard moved else {
                daemon.logger.error("chat dock: a New Tab page could not follow the chat; leaving it in its pane")
                continue
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
            if settled, services.locateTab(page.id)?.1 === dock {
                index += 1
            } else {
                daemon.logger.error("chat dock: a New Tab page's move was not reported in the dock")
            }
        }
        content.paneController(key: dock.id)?.selectWhenReportedKeepingFocus(surface: chat.surface)
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
