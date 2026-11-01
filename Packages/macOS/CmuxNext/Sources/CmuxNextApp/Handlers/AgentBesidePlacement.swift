import CmuxNextCompat
import CmuxNextActions
import CmuxNextAgentPane
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
    struct Opening {
        var created: @MainActor (SurfaceID) -> Void
        var failed: @MainActor (ActionWorkFailure?) -> Void
    }

    private enum Outcome: Sendable {
        case created(SurfaceID)
        case failed(ActionWorkFailure?)
    }

    /// How long the move waits for the new tab: its open, then the store's echo.
    static let openLimit: Duration = .seconds(30)

    /// The `then` of a tab an agent opens in `controller` beside its chat;
    /// `then` runs first. Call it while the handler runs: the move into a
    /// new column is work of the run (`registry.track`), so `action.run`
    /// answers after it, with the tab in its final pane.
    @MainActor static func placed(_ invocation: ActionInvocation, in controller: PaneController,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        opening(invocation, pane: controller.pane, controller: controller, services: controller.services, then: then, waitsForExisting: false).created
    }

    /// Same for `pane` whether a window shows it or not: a chat in a
    /// workspace no window shows still gets its new column (daemon commands);
    /// only the selection in an existing column needs the shown pane.
    @MainActor static func placed(_ invocation: ActionInvocation, pane anchor: PaneModel, controller: PaneController?,
                                  services: AppServices,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        opening(invocation, pane: anchor, controller: controller, services: services, then: then, waitsForExisting: false).created
    }

    @MainActor static func opening(_ invocation: ActionInvocation, in controller: PaneController,
                                   then: (@MainActor (SurfaceID) -> Void)?) -> Opening {
        opening(invocation, pane: controller.pane, controller: controller, services: controller.services, then: then)
    }

    @MainActor private static func opening(_ invocation: ActionInvocation, pane anchor: PaneModel, controller: PaneController?,
                                          services: AppServices, then: (@MainActor (SurfaceID) -> Void)?, waitsForExisting: Bool = true) -> Opening {
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
        // A lone chat docks left with the agent chat role and the new tab stays in its
        // pane (ChatColumnPlacement.dockChat, the rule a person's new tab follows), so
        // the column right of the chat is always in view; else the tab moves out.
        let caller = invocation.newColumnBeside ? controller : nil
        let pendingChat = caller.flatMap { OutboundTab.dockingChat(in: $0) }
        let lone = caller.flatMap { pendingChat != nil || ChatColumnPlacement.resolve(from: $0, services: services) == .dockChat ? $0 : nil }
        let chatID = pendingChat ?? lone?.pane.tabs.first { ChatColumnPlacement.isChat($0, services: services) }?.id
        let chatHadFocus = lone.map { $0.workspace?.focusedPane === $0 } ?? false
        // The chat's strip never lists the tab on its way out: it first shows on the right (OutboundTab).
        let outbound = (invocation.newColumnBeside ? controller : nil).flatMap { $0.pane === anchor ? OutboundTab.begin(in: $0) : nil }
        if let chatID { outbound?.hidden(whileHolding: chatID) }
        let daemon = services.daemon(for: anchor), store = daemon.store, machineID = daemon.machineID
        let (surfaces, sink) = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var finished = false
        if invocation.newColumnBeside || waitsForExisting {
        let work: ActionWork = Task { @MainActor in
            var moved = false
            defer { outbound?.finish(moved: moved) }
            // The tab's surface, then the store listing it; a bounded wait, so a tab
            // that never opens cannot hold the run.
            let listed = Task { @MainActor () -> Outcome? in
                var opened = surfaces.makeAsyncIterator()
                guard let outcome = await opened.next() else { return nil }
                guard case .created(let surface) = outcome else { return outcome }
                for await found in ObservationStream({
                    _ = store.tabListRevision
                    return store.tab(surface: surface) != nil
                }) where found { return outcome }
                return nil
            }
            let bound = DemandTimer(owner: "AgentBesidePlacement.tabOpen")
            bound.schedule(after: openLimit) { @MainActor in
                finished = true
                listed.cancel()
                sink.finish()
            }
            let outcome = await withTaskCancellationHandler { await listed.value } onCancel: {
                listed.cancel()
                sink.finish()
            }
            bound.cancel()
            if case .failed(let failure)? = outcome { return failure }
            guard case .created(let surface)? = outcome else { return "beside-caller: the new tab did not open" }
            guard invocation.newColumnBeside else { return nil }
            // Repeated opens of a still-creating diff share its surface. Place it once, then let
            // the next open reveal its final pane rather than issuing a second concurrent move.
            let release: @MainActor () -> Void = await withCheckedContinuation { done in
                services.linkOpener.turns.serially(beside: ObjectIdentifier(anchor)) { done.resume(returning: $0) }
            }
            defer { release() }
            guard let tab = store.tab(surface: surface) else {
                return "beside-caller: the new tab did not open"
            }
            if let chatID, let home = services.locateTab(chatID, onMachine: machineID)?.1, home !== anchor,
               services.locateTab(model: tab)?.1 === anchor {
                // A preceding open already docked this lone chat and left this very diff on its right.
                moved = true
                if let right = services.paneController(for: anchor), !(personActed() && right.workspace?.focusedPane === right) {
                    right.selectWhenReportedKeepingFocus(surface: surface)
                }
                if let clicked { focus(surface, returningTo: LayoutPaneID(home.id), in: clicked, generation: intent, services: services) }
                return nil
            }
            if let chatID, let (chat, home) = services.locateTab(chatID, onMachine: machineID), home === anchor, let content = lone?.workspace {
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
                    let listed = Task { @MainActor () -> Bool in
                        // The store lists the chat in its new dock pane, found by id on its machine: that pane's tabs are new
                        // TabModels, never `chat` (`locateTab(model:)`). Focus goes by the pane's id, which the window applies.
                        for await moved in ObservationStream({ services.locateTab(chat.id, onMachine: machineID).map { $0.1 !== anchor } ?? false }) where moved {
                            return true
                        }
                        return false
                    }
                    let bound = DemandTimer(owner: "AgentBesidePlacement.chatDock")
                    bound.schedule(after: openLimit) { @MainActor in listed.cancel() }
                    let moved = await listed.value
                    bound.cancel()
                    if moved, let pane = services.locateTab(chat.id, onMachine: machineID)?.1, let clicked {
                        focus(surface, returningTo: LayoutPaneID(pane.id), in: clicked, generation: intent, services: services)
                    } else if moved, let pane = services.locateTab(chat.id, onMachine: machineID)?.1 {
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
            if services.locateTab(model: tab).map({ $0.1 !== anchor }) == true {
                moved = true
                if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
                await revealMoved(tab.id, from: anchor, services: services)
                return nil
            }
            // Hold the same turn as links and dock tools until this move lands. In particular,
            // two header clicks must not both split below the one pane they initially saw.
            let finish = await withCheckedContinuation { (ready: CheckedContinuation<@MainActor () -> Void, Never>) in
                services.linkOpener.turns.serially(beside: LayoutPaneID(anchor.id)) { done in ready.resume(returning: done) }
            }
            defer { finish() }
            let source = controller ?? services.paneController(for: anchor)
            let measured = source.map { LinkOpener.rightColumn(beside: $0) } ?? RightColumnPlacement.Column()
            let kind: RightColumnPlacement.Kind? = tab.kind == .browser ? .browser : (tab.kind == .pty ? .terminal : nil)
            let decision = RightColumnPlacement.decide(measured, opening: kind)
            let destination: PaneController? = {
                guard case .tab(let id) = decision, let id else { return nil }
                return source?.workspace?.panes[LayoutPaneID(rawValue: id)]
            }()
            moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                switch decision {
                case .splitRight:
                    // The first right-side item is a pane beside the chat. Keeping this as a
                    // split (rather than the daemon's after-last-column default) also makes the
                    // right column visible while the chat keeps focus.
                    TabMoves.toNewSplit(tab, pane: anchor, edge: .right, services: services, keepFocus: true) {
                        done.resume(returning: $0)
                    }
                case .splitBelow(let id):
                    let right = source?.workspace?.panes[LayoutPaneID(rawValue: id)]
                    guard let right else { return done.resume(returning: false) }
                    TabMoves.toNewSplit(tab, pane: right.pane, edge: .bottom, services: services, keepFocus: true) {
                        done.resume(returning: $0)
                    }
                case .tab:
                    let right = destination ?? source
                    guard let right else { return done.resume(returning: false) }
                    TabMoves.move(tab, to: right.pane, index: right.pane.tabs.count, services: services) {
                        done.resume(returning: $0)
                    }
                }
            }
            guard moved else { return "beside-caller: the move into the right pane failed (see the app log)" }
            if let clicked { focus(surface, returningTo: from, awayFrom: away, in: clicked, generation: intent, services: services) }
            if case .tab = decision, let right = destination ?? source,
               !(personActed() && right.workspace?.focusedPane === right) {
                right.selectWhenReportedKeepingFocus(surface: surface)
            }
            if case .splitRight = decision { await revealMoved(tab.id, from: anchor, services: services) }
            return nil
        }
        if waitsForExisting { services.registry.trackRollingBack("openDiffViewer", work) } else { services.registry.track(work) }
        }
        return Opening(created: { [weak services, weak controller, weak clicked] surface in
            guard !finished else { return }
            finished = true
            outbound?.made(surface)
            then?(surface)
            if !invocation.newColumnBeside, let services {
                let destination = store.tab(surface: surface).flatMap { services.locateTab(model: $0)?.1 }
                    .flatMap { services.paneController(for: $0) } ?? controller
                if let destination, !(personActed() && destination.workspace?.focusedPane === destination) {
                    destination.selectWhenReportedKeepingFocus(surface: surface)
                }
                if let clicked { focus(surface, returningTo: from, in: clicked, generation: intent, services: services) }
            }
            sink.yield(.created(surface))
            sink.finish()
        }, failed: { failure in
            guard !finished else { return }
            finished = true
            sink.yield(.failed(failure))
            sink.finish()
        })
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
}

extension AgentBesidePlacement {
    /// Scrolls the new column of tab `id`, moved out of `anchor`, into view once the store lists it
    /// there; focus stays in the chat. The strip follows focus only, so a column the daemon added past
    /// the viewport (after the last column, as beside a chat docked left) stayed out of view (cx-27j7).
    @MainActor static func revealMoved(_ id: String, from anchor: PaneModel, services: AppServices) async {
        guard let content = services.paneController(for: anchor)?.workspace else { return }
        let machineID = services.daemon(for: anchor).machineID
        let listed = Task { @MainActor () -> Bool in
            for await moved in ObservationStream({ services.locateTab(id, onMachine: machineID).map { $0.1 !== anchor } ?? false }) where moved { return true }
            return false
        }
        let bound = DemandTimer(owner: "AgentBesidePlacement.reveal")
        bound.schedule(after: openLimit) { @MainActor in
            listed.cancel()
        }
        let moved = await listed.value
        bound.cancel()
        if moved, let pane = services.locateTab(id, onMachine: machineID)?.1 { content.layoutModel.revealColumn(containing: LayoutPaneID(pane.id)) }
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
