import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Observation

/// beside_caller in the app (hq-6d right-column design). The control router
/// picks the pane (ControlCaller): the column right of the agent's chat, or,
/// with no column there, the chat's own pane with `newColumnBeside`. Here the
/// new tab is made in that pane without moving keyboard focus out of the
/// chat: selected in the column right of the chat, or made unselected in the
/// chat's pane and moved into a new column right of it, so the chat pane
/// never shows it.
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
        guard invocation.newColumnBeside else {
            return { [weak controller] surface in
                then?(surface)
                controller?.selectWhenReportedKeepingFocus(surface: surface)
            }
        }
        // A lone chat docks left with the agent chat role and the new tab stays in its
        // pane (ChatColumnPlacement.dockChat, the rule a person's new tab follows), so
        // the column right of the chat is always in view; else the tab moves out.
        let lone = controller.flatMap { ChatColumnPlacement.resolve(from: $0, services: services) == .dockChat ? $0 : nil }
        let chat = lone?.pane.tabs.first { ChatColumnPlacement.isChat($0, services: services) }
        let chatHadFocus = lone.map { $0.workspace?.focusedPane === $0 } ?? false
        let (surfaces, sink) = AsyncStream<SurfaceID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        services.registry.track(Task { @MainActor in
            // The tab's surface, then the store listing it; a bounded wait, so a tab
            // that never opens cannot hold the run.
            let listed = Task { @MainActor () -> SurfaceID? in
                var opened = surfaces.makeAsyncIterator()
                guard let surface = await opened.next() else { return nil }
                for await found in Observations({ services.locateTab(surface: surface) != nil }) where found {
                    return surface
                }
                return nil
            }
            let bound = Task { @MainActor in
                try? await Task.sleep(for: openLimit)
                listed.cancel()
                sink.finish()
            }
            let surface = await listed.value
            bound.cancel()
            guard let surface, let tab = services.locateTab(surface: surface) else {
                return "beside-caller: the new tab did not open"
            }
            if let chat, let content = lone?.workspace {
                // The new tab is in the chat's pane, unselected: the chat docks, the tab stays.
                let docked = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    TabMoves.toNewDockColumn(chat, anchor: anchor, edge: .left, role: .agentChat, services: services) {
                        done.resume(returning: $0)
                    }
                }
                guard docked else { return "beside-caller: the chat did not dock (see the app log)" }
                // Keyboard focus stays in the chat, now in its dock.
                if chatHadFocus || content.focusedPane?.pane === anchor {
                    let chatID = chat.id
                    let listed = Task { @MainActor () -> Bool in
                        // The store lists the chat in its new dock pane (the window's controller may come later;
                        // focus goes by the pane's id, which the window applies when it shows the pane).
                        for await moved in Observations({ services.locateTab(chatID).map { $0.1 !== anchor } ?? false }) where moved {
                            return true
                        }
                        return false
                    }
                    let bound = Task { @MainActor in
                        try? await Task.sleep(for: openLimit)
                        listed.cancel()
                    }
                    let moved = await listed.value
                    bound.cancel()
                    if moved, let pane = services.locateTab(chatID)?.1 {
                        // Not a view change of the run: the run moved the focused chat out of its
                        // pane, and focus follows the chat back to where the person had it (as
                        // FocusCoordinator.followMovedTab does for a person's move).
                        ActionRunScope.carrying(ActionRunScope(origin: .script, allowsViewChange: true)) {
                            PaneHandlers.focus(LayoutPaneID(pane.id), in: content)
                        }
                    }
                }
                services.paneController(for: anchor)?.selectWhenReportedKeepingFocus(surface: surface)
                return nil
            }
            let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                TabMoves.toNewColumn(tab, anchor: anchor, services: services) { done.resume(returning: $0) }
            }
            return moved ? nil : "beside-caller: the move into a new column failed (see the app log)"
        })
        return { surface in
            then?(surface)
            sink.yield(surface)
            sink.finish()
        }
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
