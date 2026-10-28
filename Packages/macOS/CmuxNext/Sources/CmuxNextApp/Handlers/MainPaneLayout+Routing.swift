import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

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
        let store = controller.daemon.store, anchor = controller.pane
        let chatHadFocus = controller.workspace?.focusedPane === controller
        let reveal: @MainActor (PaneController, TabModel) -> Void = { pane, tab in
            if focus { pane.select(StripTabID(tab.id)) } else { pane.selectWhenReportedKeepingFocus(surface: surface) }
        }
        services.registry.track(Task { @MainActor [weak controller] () -> ActionWorkFailure? in
            let listed = Task { @MainActor () -> TabModel? in
                if let tab = store.tab(surface: surface) { return tab }
                // `tabListRevision`: the tracked read hears the tab appear (AppServices.locateTab).
                for await found in ObservationStream({ _ = store.tabListRevision; return store.tab(surface: surface) != nil }) where found {
                    return store.tab(surface: surface)
                }
                return nil
            }
            let bound = DemandTimer(owner: "MainPaneLayout.tabListed")
            bound.schedule(after: listLimit) { @MainActor in listed.cancel() }
            let found = await listed.value
            bound.cancel()
            guard let tab = found, let controller else {
                outbound?.finish(moved: false)
                then?(false)
                return "main pane: the new tab did not open"
            }
            guard let chat = anchor.tabs.first(where: { $0.id != tab.id && ChatColumnPlacement.isChat($0, services: services) }) else {
                outbound?.finish(moved: false)
                reveal(controller, tab)
                then?(false)
                return nil
            }
            outbound?.hidden(whileHolding: chat.id)
            // The chat stays where it shows; only the tab's pane comes in, from the right (as
            // AgentBesidePlacement docks a lone chat).
            let layout = controller.workspace?.layoutModel
            layout?.handOffContent(of: controller.layoutPaneID)
            let docked = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                TabMoves.toNewDockColumn(chat, anchor: anchor, edge: .left, role: .agentChat, services: services) { done.resume(returning: $0) }
            }
            guard docked else {
                layout?.cancelContentHandoff()
                outbound?.finish(moved: false)
                reveal(controller, tab)
                if focus { controller.focusContent() }
                then?(false)
                return "main pane: the chat did not dock (see the app log)"
            }
            // Selected once the store has the chat in its dock: until then the strip leaves the tab out.
            let dock = await movedPane(of: chat.id, from: anchor, services: services)
            outbound?.finish(moved: dock != nil)
            reveal(controller, tab)
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
        })
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
            services.locateTab(key).map { (pane: $0.1.handle, daemon: services.machines.daemon(forTab: $0.0)) }
        }
        // task-owner: one tab creation, then one selection (or the chat's dock) for it
        Task { @MainActor [weak target] in
            guard let tab = try? await pending.value(), await TabMirror.reaches(tab.key, in: locate), let target else {
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
            if focus, let model = services.locateTab(tab.key)?.0 {
                target.select(StripTabID(model.id))
                if let content = target.workspace { PaneHandlers.focus(target.layoutPaneID, in: content) }
            } else {
                // An agent's open: selected in the column, keyboard focus stays where it is.
                target.selectWhenReportedKeepingFocus(surface: tab.surface)
            }
            finished?(true)
        }
        return true
    }

    /// The pane chat tab `id` moved into from `anchor`, once the store lists it there (nil after
    /// ``listLimit``).
    @MainActor private static func movedPane(of id: String, from anchor: PaneModel, services: AppServices) async -> PaneModel? {
        let moved = Task { @MainActor () -> Bool in
            for await moved in ObservationStream({ services.locateTab(id).map { $0.1 !== anchor } ?? false }) where moved {
                return true
            }
            return false
        }
        let bound = DemandTimer(owner: "MainPaneLayout.chatDock")
        bound.schedule(after: listLimit) { @MainActor in moved.cancel() }
        let found = await moved.value
        bound.cancel()
        return found ? services.locateTab(id)?.1 : nil
    }
}
