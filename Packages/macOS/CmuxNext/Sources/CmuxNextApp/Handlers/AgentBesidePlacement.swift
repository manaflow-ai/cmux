import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
    /// `limit`: how long the move waits for the tab's open and for each store echo (``openLimit``; tests pass a short one).
    @MainActor static func placed(_ invocation: ActionInvocation, pane anchor: PaneModel, controller: PaneController?,
                                  services: AppServices, limit: Duration = openLimit,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        // A person's click: the pane they clicked in, which the tab's close focuses again.
        let clicked = invocation.besideTakesFocus ? (controller?.workspace ?? services.paneController(for: anchor)?.workspace) : nil
        let intent = clicked?.beginFocusIntent(), from = clicked?.focusedPane?.layoutPaneID
        // An agent's open: what the person does meanwhile (a link clicked mid-turn) wins over it.
        let watched = clicked == nil ? (controller?.workspace ?? services.paneController(for: anchor)?.workspace) : nil
        let asked = watched?.focus.state.generation
        let personActed: @MainActor @Sendable () -> Bool = { [weak watched] in
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
        // The waits run off main; each step on main is one task of the run's completion (userBlocking for the
        // person's click, automation for an agent's open), as Chromium posts each reply of off-thread work.
        let end = services.registry.completion(on: services.mainWork)
        // A bounded wait, so a tab that never opens cannot hold the run: the bound ends the stream.
        let bound = MainDeadline(owner: "AgentBesidePlacement.tabOpen", workClass: end.workClass, scheduler: services.mainDeadlines)
        bound.schedule(after: limit) { sink.finish() }
        let store = services.daemon(for: anchor).store, chatID = chat?.id
        // The run's last step: the strip lists the tab again, and the run answers.
        let done: @MainActor @Sendable (Bool, ActionWorkFailure?) -> ActionWorkFailure? = { moved, failure in
            bound.cancel()
            outbound?.finish(moved: moved)
            return failure
        }
        services.registry.track(end.start { () -> ActionWorkFailure? in
            // The tab's surface, then the store listing it: StoreWaiters reads again only when the store keys it.
            var opened = surfaces.makeAsyncIterator()
            let surface = await opened.next()
            var listed: TabModel?
            if let surface { listed = await store.waitForTab(surface: surface, timeout: limit) }
            guard let surface, let tab = listed else {
                return await end.apply(owner: "AgentBesidePlacement.notOpened", answering: true) {
                    done(false, "beside-caller: the new tab did not open")
                }
            }
            if let chat, let lone, let chatID {
                // The new tab is in the chat's pane, unselected: the chat docks, the tab stays. The chat stays
                // where it shows; only the tab's pane comes in, from the right. A move that drops its callback
                // did not dock.
                let step = (try? await withOnceContinuation { (docking: OnceContinuation<DockStep, OnceContinuationError>) in
                    end.post(owner: "AgentBesidePlacement.dockChat") {
                        guard let content = lone.workspace else {
                            docking.resume(returning: .noContent)
                            return
                        }
                        content.layoutModel.handOffContent(of: lone.layoutPaneID)
                        TabMoves.toNewDockColumn(chat, anchor: anchor, edge: .left, role: .agentChat, services: services) { docked in
                            guard docked else {
                                content.layoutModel.cancelContentHandoff()
                                docking.resume(returning: .notDocked)
                                return
                            }
                            // Keyboard focus stays in the chat, now in its dock; a person's click focuses the tab.
                            // Not when the person acted since the run began: their focus stays where they put it.
                            let follows = (chatHadFocus || content.focusedPane?.pane === anchor) && !personActed()
                            docking.resume(returning: .docked(follows: follows))
                        }
                    }
                }) ?? .notDocked
                switch step {
                case .notDocked:
                    return await end.apply(owner: "AgentBesidePlacement.notDocked", answering: true) {
                        done(false, "beside-caller: the chat did not dock (see the app log)")
                    }
                case .docked(let follows):
                    // The store lists the chat in its new dock pane (the window's controller may come later;
                    // focus goes by the pane's id, which the window applies when it shows the pane).
                    let dock: PaneModel?
                    if follows {
                        dock = await movedPane(of: chatID, from: anchor, limit: limit, workClass: end.workClass, services: services)
                    } else {
                        dock = nil
                    }
                    return await end.apply(owner: "AgentBesidePlacement.docked", answering: true) {
                        if let dock, let clicked {
                            focus(surface, returningTo: LayoutPaneID(dock.id), in: clicked, generation: intent, services: services)
                        } else if let dock, let content = lone.workspace {
                            // Not a view change of the run: the run moved the focused chat out of its
                            // pane, and focus follows the chat back to where the person had it (as
                            // FocusCoordinator.followMovedTab does for a person's move). Programmatic, so
                            // it is not the person acting for another open in flight (`personActed`).
                            ActionRunScope.carrying(ActionRunScope(origin: .script, allowsViewChange: true)) {
                                content.focus.send(.focusPane(dock.id, source: .programmatic))
                            }
                        }
                        if let left = services.paneController(for: anchor), !(personActed() && lone.workspace?.focusedPane === left) {
                            left.selectWhenReportedKeepingFocus(surface: surface)
                        }
                        return done(true, nil)
                    }
                case .noContent:
                    break
                }
            }
            let step = (try? await withOnceContinuation { (moving: OnceContinuation<MoveStep, OnceContinuationError>) in
                end.post(owner: "AgentBesidePlacement.moveTab") {
                    let away = services.paneController(for: anchor)?.paneKey
                    // Home's pinned dock alone takes no tab: the daemon made it in a new column right of
                    // the dock (`pinned-dock-alone-v1`), so there is nothing to move.
                    // view-observation-allow: one MachineTabIndex lookup, once
                    if services.locateTab(tab.id).map({ $0.1 !== anchor }) == true {
                        if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
                        moving.resume(returning: .moved(tab.id))
                        return
                    }
                    let after = newColumn(beside: anchor, in: store)
                    TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services) { moved in
                        guard moved else {
                            moving.resume(returning: .notMoved)
                            return
                        }
                        if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
                        moving.resume(returning: .moved(tab.id))
                    }
                }
            }) ?? .notMoved
            guard case .moved(let id) = step else {
                return await end.apply(owner: "AgentBesidePlacement.notMoved", answering: true) {
                    done(false, "beside-caller: the move into a new column failed (see the app log)")
                }
            }
            // The strip follows focus only: the new column scrolls into view once the store lists the tab there.
            let pane = await movedPane(of: id, from: anchor, limit: limit, workClass: end.workClass, services: services)
            return await end.apply(owner: "AgentBesidePlacement.reveal", answering: true) {
                if let pane, let content = services.paneController(for: anchor)?.workspace {
                    content.layoutModel.revealColumn(containing: LayoutPaneID(pane.id))
                }
                return done(true, nil)
            }
        })
        return { surface in
            outbound?.made(surface)
            then?(surface)
            sink.yield(surface)
            sink.finish()
        }
    }

    /// Where a lone chat's dock got to (``placed(_:pane:controller:services:then:)``).
    private nonisolated enum DockStep: Sendable {
        /// The chat's pane shows in no window: the tab moves out instead.
        case noContent
        /// The chat's move into a dock failed.
        case notDocked
        /// The chat docked; `follows`: keyboard focus follows it into the dock.
        case docked(follows: Bool)
    }

    /// Where the tab's move out of the chat's pane got to.
    private nonisolated enum MoveStep: Sendable {
        case notMoved
        /// The tab (its id) is in a column of its own.
        case moved(String)
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
        if let pane = await movedPane(of: id, from: anchor, workClass: .visible, services: services) {
            content.layoutModel.revealColumn(containing: LayoutPaneID(pane.id))
        }
    }

    /// The pane tab `id` is in once the store lists it outside `anchor`, else nil after `limit`: one
    /// `ObservedCondition` (a `ServiceObservation` in `workClass`) reads the tab index again only when it moves.
    @MainActor static func movedPane(of id: String, from anchor: PaneModel, limit: Duration = openLimit,
                                     workClass: BudgetedWorkClass, services: AppServices) async -> PaneModel? {
        // view-observation-allow: one MachineTabIndex lookup per read
        let moved: @MainActor () -> PaneModel? = { services.locateTab(id).flatMap { $0.1 !== anchor ? $0.1 : nil } }
        await ObservedCondition(owner: "AgentBesidePlacement.moved", workClass, on: services.mainWork)
            .until(timeout: limit, deadlines: services.mainDeadlines) { moved() != nil }
        return moved()
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
