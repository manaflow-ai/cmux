import CmuxNextCompat
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import CmuxNextWakeups

/// beside_caller in the app (hq-6d right-column design). The control router
/// picks the pane (ControlCaller): the column right of the agent's chat, or,
/// with no column there, the chat's own pane with `newColumnBeside`. Here the
/// new tab is made in that pane without moving keyboard focus out of the
/// chat: selected in the column right of the chat, or made unselected in the
/// chat's pane and moved into a new column right of it, so the chat pane
/// never shows it. A person's click from the chat (the header's Changes,
/// Preview or Files, ``ActionInvocation/besideTakesFocus``) lands the same
/// way, but its tab takes the focus and its close gives it back to the chat.
enum AgentBesidePlacement {
    /// How long the move waits for the new tab: its open, then the store's echo.
    static let openLimit: Duration = .seconds(30)

    /// The `then` of a tab an agent opens in `controller` beside its chat;
    /// `then` runs first. Call it while the handler runs: the move into a
    /// new column is work of the run (`registry.track`), so `action.run`
    /// answers after it, with the tab in its final pane.
    @MainActor static func placed(_ invocation: ActionInvocation, in controller: PaneController,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        placed(invocation, pane: controller.pane, controller: controller, services: controller.services, then: then)
    }

    /// Same for `pane` whether a window shows it or not: a chat in a
    /// workspace no window shows still gets its new column (daemon commands);
    /// only the selection in an existing column needs the shown pane.
    @MainActor static func placed(_ invocation: ActionInvocation, pane anchor: PaneModel, controller: PaneController?,
                                  services: AppServices,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        // A person's click: the pane they clicked in, which the tab's close focuses again.
        let clicked = invocation.besideTakesFocus ? (controller?.workspace ?? services.paneController(for: anchor)?.workspace) : nil
        let intent = clicked?.beginFocusIntent(), from = clicked?.focusedPane?.layoutPaneID
        // An agent's open: what the person does meanwhile (a link clicked mid-turn) wins over it.
        let watched = clicked == nil ? (controller?.workspace ?? services.paneController(for: anchor)?.workspace) : nil
        let asked = watched?.focus.state.generation
        let personActed: @MainActor () -> Bool = { [weak watched] in
            guard let asked, let watched else { return false }
            return watched.focus.state.generation != asked
        }
        guard invocation.newColumnBeside else {
            return { [weak controller, weak clicked, weak services] surface in
                then?(surface)
                // Never swaps out the tab the person has in front of them since the run began.
                if let controller, !(personActed() && controller.workspace?.focusedPane === controller) {
                    controller.selectWhenReportedKeepingFocus(surface: surface)
                }
                if let services, let clicked { focus(surface, returningTo: from, in: clicked, generation: intent, services: services) }
            }
        }
        // A lone chat docks left with the agent chat role and the new tab stays in its
        // pane (ChatColumnPlacement.dockChat, the rule a person's new tab follows), so
        // the column right of the chat is always in view; else the tab moves out.
        let lone = controller.flatMap { ChatColumnPlacement.resolve(from: $0, services: services) == .dockChat ? $0 : nil }
        let chat = lone?.pane.tabs.first { ChatColumnPlacement.isChat($0, services: services) }
        let chatHadFocus = lone.map { $0.workspace?.focusedPane === $0 } ?? false
        // The chat's strip never lists the tab on its way out: it first shows on the right (OutboundTab).
        let outbound = controller.flatMap { $0.pane === anchor ? OutboundTab.begin(in: $0) : nil }
        if let chat { outbound?.hidden(whileHolding: chat.id) }
        let (surfaces, sink) = AsyncStream<SurfaceID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        services.registry.track(Task { @MainActor in
            var moved = false
            defer { outbound?.finish(moved: moved) }
            // The tab's surface, then the store listing it; a bounded wait, so a tab
            // that never opens cannot hold the run.
            let listed = Task { @MainActor () -> SurfaceID? in
                var opened = surfaces.makeAsyncIterator()
                guard let surface = await opened.next() else { return nil }
                for await found in ObservationStream({ services.locateTab(surface: surface) != nil }) where found {
                    return surface
                }
                return nil
            }
            let bound = DemandTimer(owner: "AgentBesidePlacement.tabOpen")
            bound.schedule(after: openLimit) { @MainActor in
                listed.cancel()
                sink.finish()
            }
            let surface = await listed.value
            bound.cancel()
            guard let surface, let tab = services.locateTab(surface: surface) else {
                return "beside-caller: the new tab did not open"
            }
            if let chat, let content = lone?.workspace {
                // The new tab is in the chat's pane, unselected: the chat docks, the tab stays. The
                // chat stays where it shows; only the tab's pane comes in, from the right.
                if let lone { content.layoutModel.handOffContent(of: lone.layoutPaneID) }
                let docked = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    TabMoves.toNewDockColumn(chat, anchor: anchor, edge: .left, role: .agentChat, services: services) {
                        done.resume(returning: $0)
                    }
                }
                guard docked else {
                    content.layoutModel.cancelContentHandoff()
                    return "beside-caller: the chat did not dock (see the app log)"
                }
                moved = true
                // Keyboard focus stays in the chat, now in its dock; a person's click focuses the tab.
                // Not when the person acted since the run began: their focus stays where they put it.
                if (chatHadFocus || content.focusedPane?.pane === anchor) && !personActed() {
                    let chatID = chat.id
                    let listed = Task { @MainActor () -> Bool in
                        // The store lists the chat in its new dock pane (the window's controller may come later;
                        // focus goes by the pane's id, which the window applies when it shows the pane).
                        for await moved in ObservationStream({ services.locateTab(chatID).map { $0.1 !== anchor } ?? false }) where moved {
                            return true
                        }
                        return false
                    }
                    let bound = DemandTimer(owner: "AgentBesidePlacement.chatDock")
                    bound.schedule(after: openLimit) { @MainActor in
                        listed.cancel()
                    }
                    let moved = await listed.value
                    bound.cancel()
                    if moved, let pane = services.locateTab(chatID)?.1, let clicked {
                        focus(surface, returningTo: LayoutPaneID(pane.id), in: clicked, generation: intent, services: services)
                    } else if moved, let pane = services.locateTab(chatID)?.1 {
                        // Not a view change of the run: the run moved the focused chat out of its
                        // pane, and focus follows the chat back to where the person had it (as
                        // FocusCoordinator.followMovedTab does for a person's move). Programmatic, so
                        // it is not the person acting for another open in flight (`personActed`).
                        ActionRunScope.carrying(ActionRunScope(origin: .script, allowsViewChange: true)) {
                            content.focus.send(.focusPane(pane.id, source: .programmatic))
                        }
                    }
                }
                if let left = services.paneController(for: anchor), !(personActed() && content.focusedPane === left) {
                    left.selectWhenReportedKeepingFocus(surface: surface)
                }
                return nil
            }
            // Home's pinned dock alone takes no tab: the daemon made it in a new column right of
            // the dock (`pinned-dock-alone-v1`), so there is nothing to move.
            let away = services.paneController(for: anchor)?.paneKey
            if services.locateTab(tab.id).map({ $0.1 !== anchor }) == true {
                moved = true
                if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
                await revealMoved(tab.id, from: anchor, services: services)
                return nil
            }
            let after = newColumn(beside: anchor, in: services.daemon(for: anchor).store)
            moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services) { done.resume(returning: $0) }
            }
            guard moved else { return "beside-caller: the move into a new column failed (see the app log)" }
            if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
            await revealMoved(tab.id, from: anchor, services: services)
            return nil
        })
        return { surface in
            outbound?.made(surface)
            then?(surface)
            sink.yield(surface)
            sink.finish()
        }
    }
}

extension AgentBesidePlacement {
    /// A person's click (``ActionInvocation/besideTakesFocus``): the focus goes to `surface`'s tab once
    /// it lands (once it left pane `awayFrom`, a tab made there and moved), unless they acted after
    /// `generation`; the close that empties its pane gives the focus back to pane `chat` (``LinkOpener/returnPane(closing:in:emptiesPane:)``).
    @MainActor static func focus(_ surface: SurfaceID, returningTo chat: LayoutPaneID?, awayFrom pane: String? = nil,
                                 in content: WorkspaceContentController, generation: UInt64?, services: AppServices) {
        if let chat { services.linkOpener.returnFocus(of: surface, to: chat, in: content) }
        content.expectFocus(on: surface, awayFrom: pane, generation: generation)
    }

    /// The column a tab beside `chat` follows: the chat's own scrolling column, so the new column
    /// opens right of the chat, where the chat keeping focus keeps it in view. The daemon's
    /// default is after the last column, past the panes already beside the chat and off screen
    /// (cx-u1yn). Nil for a chat in a docked column or on a screen without columns.
    static func newColumn(beside chat: PaneModel, in store: DaemonStore) -> DaemonColumnID? {
        guard let screen = store.workspace(containing: chat.handle)?.screens.first(where: { $0.panes.contains { $0 === chat } }),
              let column = screen.columns.first(where: { $0.layout.paneIDs.contains(chat.handle) }),
              column.dock == nil else { return nil }
        return column.id
    }
}

extension AgentBesidePlacement {
    /// Scrolls the new column of tab `id`, moved out of `anchor`, into view once the store lists it
    /// there; focus stays in the chat. The strip follows focus only, so a column the daemon added past
    /// the viewport (after the last column, as beside a chat docked left) stayed out of view (cx-27j7).
    @MainActor static func revealMoved(_ id: String, from anchor: PaneModel, services: AppServices) async {
        guard let content = services.paneController(for: anchor)?.workspace else { return }
        let listed = Task { @MainActor () -> Bool in
            for await moved in ObservationStream({ services.locateTab(id).map { $0.1 !== anchor } ?? false }) where moved { return true }
            return false
        }
        let bound = DemandTimer(owner: "AgentBesidePlacement.reveal")
        bound.schedule(after: openLimit) { @MainActor in
            listed.cancel()
        }
        let moved = await listed.value
        bound.cancel()
        if moved, let pane = services.locateTab(id)?.1 { content.layoutModel.revealColumn(containing: LayoutPaneID(pane.id)) }
    }
}

extension PaneController {
    /// Selects `surface`'s tab in this pane once the store reports it, and
    /// moves no keyboard focus: an agent's tab opened beside its chat.
    func selectWhenReportedKeepingFocus(surface: SurfaceID) {
        pendingSelectSurface = surface
        apply(snapshot())
    }
}
