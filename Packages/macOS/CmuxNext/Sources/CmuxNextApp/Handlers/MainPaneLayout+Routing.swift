import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Main pane layout in the app (``MainPaneLayout``, `layout.mainPane`): what an agent chat opens from its
/// pane goes beside it. ``LinkOpener`` (links, files, folders) and ``AgentTabStore``'s side and
/// subagent panes ask here first.
extension MainPaneLayout {
    /// How long a dock waits for the store to list the new tab, then for the chat to move.
    static let listLimit: Duration = .seconds(30)

    /// Whether main pane layout is on now: the Debug override, else `layout.mainPane` (its default
    /// before settings load).
    @MainActor static func isOn(services: AppServices) -> Bool {
        isOn(setting: (services.settings?.snapshot.mainPane ?? MainPaneSetting.fallback) == .agentChats, override: debugOverride.value)
    }

    /// Where what `controller`'s pane opens goes in main pane layout, or nil (off, or not a main pane).
    @MainActor static func side(from controller: PaneController, services: AppServices) -> ChatColumnPlacement? {
        guard isOn(services: services) else { return nil }
        return side(of: ChatColumnPlacement.resolve(from: controller, services: services))
    }

    /// The lone chat in `controller`'s pane docks left with the agent chat role; the tab on
    /// `surface`, just opened there unselected, stays and is selected, so its pane becomes the
    /// column on the chat's right. With `focus` (a person's click) the tab takes keyboard focus;
    /// else no focus moves to it, and focus follows the chat into its dock when the chat had it
    /// (an agent's open stays in the background). A failed dock selects the tab where it is, so it
    /// never stays hidden. `then` hears whether the chat docked, once the store lists it in its
    /// dock, so a later open sees the column on its right. `outbound`: the pane's strip leaves the tab
    /// out until the chat has left, so it first shows in the pane on the right (``OutboundTab``).
    @MainActor static func dockChat(of controller: PaneController, keeping surface: SurfaceID, focus: Bool, services: AppServices,
                                    outbound: OutboundTab? = nil, then: (@MainActor (Bool) -> Void)? = nil) {
        let store = controller.daemon.store, anchor = controller.pane, mainWork = services.mainWork, limit = listLimit
        let chatHadFocus = controller.workspace?.focusedPane === controller
        let reveal: @MainActor @Sendable (PaneController, TabModel) -> Void = { pane, tab in
            if focus { pane.select(StripTabID(tab.id)) } else { pane.selectWhenReportedKeepingFocus(surface: surface) }
        }
        // The waits are awaited off main; each step on main is one task of the run's completion class (the chat's
        // move and the tab's selection show on screen), with the run's scopes.
        let end = services.registry.completion(on: mainWork)
        services.registry.trackWork(owner: "MainPaneLayout.dockChat", on: mainWork) { [weak controller] () -> (DockStep, PaneModel?) in
            // StoreWaiters: read again only when the store keys `surface`.
            let listed = await store.waitForTab(surface: surface, timeout: limit)
            // A step dropped before it ran opened nothing.
            let step = (try? await withOnceContinuation { (done: OnceContinuation<DockStep, OnceContinuationError>) in
                end.post(owner: "MainPaneLayout.dockChat.move") { [weak controller] in
                    guard let tab = listed, let controller else {
                        done.resume(returning: .notOpened)
                        return
                    }
                    guard let chat = anchor.tabs.first(where: { $0.id != tab.id && ChatColumnPlacement.isChat($0, services: services) }) else {
                        done.resume(returning: .noChat(tab))
                        return
                    }
                    outbound?.hidden(whileHolding: chat.id)
                    // The chat stays where it shows; only the tab's pane comes in, from the right (as
                    // AgentBesidePlacement docks a lone chat).
                    let layout = controller.workspace?.layoutModel
                    layout?.handOffContent(of: controller.layoutPaneID)
                    TabMoves.toNewDockColumn(chat, anchor: anchor, edge: .left, role: .agentChat, services: services) { docked in
                        if !docked { layout?.cancelContentHandoff() }
                        done.resume(returning: docked ? .docked(tab, chat: chat.id) : .notDocked(tab))
                    }
                }
            }) ?? .notOpened
            // Selected once the store has the chat in its dock: until then the strip leaves the tab out.
            guard case .docked(_, let chat) = step else { return (step, nil) }
            return (step, await movedPane(of: chat, from: anchor, services: services))
        } then: { [weak controller] result in
            guard case .success(let (step, dock)) = result, let controller else {
                outbound?.finish(moved: false)
                then?(false)
                return "main pane: the new tab did not open"
            }
            switch step {
            case .notOpened:
                outbound?.finish(moved: false)
                then?(false)
                return "main pane: the new tab did not open"
            case .noChat(let tab):
                outbound?.finish(moved: false)
                reveal(controller, tab)
                then?(false)
                return nil
            case .notDocked(let tab):
                outbound?.finish(moved: false)
                reveal(controller, tab)
                if focus { controller.focusContent() }
                then?(false)
                return "main pane: the chat did not dock (see the app log)"
            case .docked(let tab, _):
                outbound?.finish(moved: dock != nil)
                reveal(controller, tab)
            }
            // A hidden tab bar was the chat's choice: the pane it left shows its tab bar again.
            if services.paneTabBars.choice(for: controller.paneKey) == false {
                services.paneTabBars.set(nil, for: controller.paneKey)
                controller.apply(controller.snapshot())
            }
            if let content = controller.workspace {
                if focus {
                    PaneHandlers.focus(controller.layoutPaneID, in: content)
                } else if chatHadFocus, let dock {
                    // Not a view change of the open: the chat moved out of the focused pane, and focus follows
                    // it back to where the person had it (FocusCoordinator.followMovedTab does so for a move).
                    ActionRunScope.carrying(ActionRunScope(origin: .script, allowsViewChange: true)) {
                        PaneHandlers.focus(LayoutPaneID(dock.id), in: content)
                    }
                }
            }
            then?(true)
            return nil
        }
    }

    /// Where a dock of ``dockChat(of:keeping:focus:services:outbound:then:)`` got to before its last step.
    private nonisolated enum DockStep: Sendable {
        /// The store did not list the new tab within ``listLimit``, or its pane closed.
        case notOpened
        /// No chat shares the tab's pane: the tab shows where it is.
        case noChat(TabModel)
        /// The chat's move into a dock failed.
        case notDocked(TabModel)
        /// The chat (its id) moved into a new left dock.
        case docked(TabModel, chat: String)
    }

    /// Opens an agent tab (a subagent's or a side chat's pane) that chat `controller` opens beside
    /// itself, where main pane layout's `side` puts it: through `open` as a tab in the strip pane
    /// right of the chat dock, or in the lone chat's pane, which then docks the chat left
    /// (``dockChat(of:keeping:focus:services:outbound:then:)``). `created` hears the new tab's key once the
    /// tree lists it, `finished` whether it landed beside the chat. With `focus` the tab takes
    /// keyboard focus; else it is only selected there. False when nothing opened.
    @MainActor static func openAgentTab(from controller: PaneController, side: ChatColumnPlacement, focus: Bool, services: AppServices,
                                        open: (DaemonPaneID, DaemonService) throws -> AgentTabPending,
                                        created: (@MainActor (String) -> Void)?, finished: (@MainActor (Bool) -> Void)?) -> Bool {
        let target: PaneController, outbound: OutboundTab?
        switch side {
        case .tab(let id):
            guard let strip = controller.workspace?.panes[id] else { return false }
            (target, outbound) = (strip, nil)
        case .dockChat:
            // Made in the chat's pane, it stays out of the chat's strip until the chat has docked.
            (target, outbound) = (controller, OutboundTab.begin(in: controller))
        case .here, .besideDock:
            return false
        }
        guard let pending = try? open(target.pane.handle, target.daemon) else {
            outbound?.finish(moved: false)
            return false
        }
        // The stand-in tab shows at once: by its id (and the store's tab that replaces it), not as any new tab.
        outbound?.made(key: pending.key)
        let locate: TabMirror.Locate = { key in
            // view-observation-allow: one MachineTabIndex lookup per read of TabMirror's wait
            services.locateTab(key).map { (pane: $0.1.handle, daemon: services.machines.daemon(forTab: $0.0)) }
        }
        let end = services.registry.completion(on: services.mainWork)
        let mainWork = services.mainWork
        // One tab creation and its mirror are awaited off main, then the run's completion selects it (or docks the chat).
        end.start { [weak target] in
            var listed: AgentTabCreated?
            if let tab = try? await pending.value(), await TabMirror.reaches(tab.key, in: locate, on: mainWork) { listed = tab }
            let shown = listed
            end.post(owner: "MainPaneLayout.openAgentTab", answering: true) { [weak target] in
                place(listed: shown, in: target, from: controller, focus: focus, services: services,
                      outbound: outbound, created: created, finished: finished)
            }
        }
        return true
    }

    /// Shows agent tab `tab`, which the tree lists now, in `target` (``openAgentTab(from:side:focus:services:open:created:finished:)``):
    /// selected there, or in the chat's own pane, which then docks the chat. Nil `tab` or `target`: nothing opened.
    @MainActor private static func place(listed tab: AgentTabCreated?, in target: PaneController?, from controller: PaneController,
                                         focus: Bool, services: AppServices, outbound: OutboundTab?,
                                         created: (@MainActor (String) -> Void)?, finished: (@MainActor (Bool) -> Void)?) {
        guard let tab, let target else {
            outbound?.finish(moved: false)
            finished?(false)
            return
        }
        created?(tab.key)
        if target === controller {
            outbound?.made(tab.surface)
            // `finished` once the chat is in its dock: a queued open then sees the column on its right.
            dockChat(of: target, keeping: tab.surface, focus: focus, services: services, outbound: outbound) { _ in finished?(true) }
            return
        }
        // view-observation-allow: one MachineTabIndex lookup, once
        if focus, let model = services.locateTab(tab.key)?.0 {
            target.select(StripTabID(model.id))
            if let content = target.workspace { PaneHandlers.focus(target.layoutPaneID, in: content) }
        } else {
            // An agent's open: selected in the column, keyboard focus stays where it is.
            target.selectWhenReportedKeepingFocus(surface: tab.surface)
        }
        finished?(true)
    }

    /// The pane chat tab `id` moved into from `anchor`, once the store lists it there (nil after
    /// ``listLimit``). One `ServiceObservation` reads the tab's pane again only when the tab index moves.
    @MainActor private static func movedPane(of id: String, from anchor: PaneModel, services: AppServices) async -> PaneModel? {
        // view-observation-allow: one MachineTabIndex lookup per read
        let moved: @MainActor () -> PaneModel? = { services.locateTab(id).flatMap { $0.1 !== anchor ? $0.1 : nil } }
        await ObservedCondition(owner: "MainPaneLayout.chatDock", .visible, on: services.mainWork)
            .until(timeout: listLimit, deadlines: services.mainDeadlines) { moved() != nil }
        return moved()
    }
}
