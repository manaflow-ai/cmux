import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWakeups
import CmuxNextWindowRules
import Foundation

extension ChatColumnPlacement {
    /// The chat rules' read of `controller`'s pane (`chat::read`); nil when no screen shows it or no answer. `ignoringPages`:
    /// a lone chat with a New Tab page beside it is still alone. `zoomed` defaults to the workspace's zoomed pane.
    @MainActor static func read(_ controller: PaneController, services: AppServices, ignoringPages: Bool = false,
                                zoomed: Bool? = nil, moving: WindowRules.ChatMoving? = nil) -> WindowRules.ChatColumnRead? {
        guard let content = controller.workspace,
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return nil }
        let pane = controller.layoutPaneID
        let zoomed = zoomed ?? content.workspace.screens.contains { screen in
            screen.zoomedPane != nil && screen.panes.contains { $0 === controller.pane }
        }
        let columns = columns(of: screen, containing: pane).map { column in
            WindowRules.ChatColumn(panes: column.root.panes.map(\.rawValue),
                                   dock: column.dock.map { .init(role: $0.role?.rawValue, pinned: $0.isPinned, allowsTabs: $0.allowsTabs) },
                                   loneChat: column.root.contains(pane) && isLoneChat(column, in: content, ignoringPages: ignoringPages, services: services))
        }
        return WindowRules().chatColumn(pane: pane.rawValue, columns: columns, recent: content.recentPanes.map(\.rawValue),
                                        zoomed: zoomed, moving: moving)
    }

    /// Whether `column` is one pane holding one agent chat (`ignoringPages`: and any New Tab pages).
    @MainActor private static func isLoneChat(_ column: LayoutColumn, in content: WorkspaceContentController, ignoringPages: Bool,
                                              services: AppServices) -> Bool {
        guard column.root.panes.count == 1, let tabs = content.panes[column.root.panes[0]]?.pane.tabs else { return false }
        return loneChat(in: tabs, isChat: { isChat($0, services: services) },
                        isNewTabPage: { ignoringPages && services.agentTabs.isNewTabPage($0.id) }) != nil
    }

    /// What a person's new tab from `controller`'s pane becomes; `.here` on a daemon without dock roles
    /// (`dock-column-role-v1`), which never asks the rule: it reads topology only.
    @MainActor static func resolve(from controller: PaneController, services: AppServices, ignoringPages: Bool = false) -> ChatColumnPlacement {
        guard controller.workspace?.daemon.supports(DaemonCapability.dockColumnRole.rawValue) == true,
              let read = read(controller, services: services, ignoringPages: ignoringPages) else { return .here }
        switch read.placement {
        case .here: return .here
        case .tab(let pane): return .tab(in: LayoutPaneID(rawValue: pane))
        case .dockChat: return .dockChat
        case .besideDock: return .besideDock
        }
    }

    /// Whether a person's New Tab page from `controller`'s pane opens there (the chat dock's top pane), and whether
    /// `controller` is a pane Split Down made below the chat in the chat dock (#29848).
    @MainActor static func keepsNewTabPage(in controller: PaneController) -> Bool { read(controller, services: controller.services)?.keepsNewTabPage ?? false }
    @MainActor static func isBelowChat(_ controller: PaneController) -> Bool { read(controller, services: controller.services)?.belowChat ?? false }

    /// The strip pane a terminal or browser picked on a New Tab page in `controller`'s pane opens in,
    /// nil when the pick takes the page's place.
    @MainActor static func pagePick(from controller: PaneController) -> PaneController? {
        guard let id = read(controller, services: controller.services)?.pagePick, let strip = controller.workspace?.panes[LayoutPaneID(rawValue: id)],
              strip !== controller else { return nil }
        return strip
    }

    /// Whether `tab` is an agent chat. The New Tab page is an agent tab too, but not a chat.
    /// Reads `tab` itself: finding it again by id walks every workspace's tabs, once per
    /// tab of a pane whose tab bar is drawn (cx-6so.21).
    @MainActor static func isChat(_ tab: TabModel, services: AppServices) -> Bool {
        tab.agentSession != nil && !services.agentTabs.isNewTabPage(tab.id)
    }

    /// A terminal or browser opened from the chat dock uses its right column: split below its
    /// one pane, then add tabs in the lower pane. The open waits for preceding right-side opens
    /// before measuring; the New Tab page keeps `route` and its own docking behavior.
    @MainActor static func openTool(from controller: PaneController, services: AppServices, background: Bool = false,
                                    kind: RightColumnPlacement.Kind? = nil,
                                    _ make: @escaping LinkOpener.Make) -> Bool {
        guard case .tab = resolve(from: controller, services: services) else { return false }
        services.linkOpener.open(from: controller, background: background, besideChat: true, kind: kind, opening: .tool, make)
        return true
    }

    /// Where a person's new tab from `controller`'s pane opens: the pane
    /// to open it in (`controller` itself, or the strip pane, focused), or
    /// nil when it is already open. A lone chat moves into a new left dock
    /// with the agent chat role, leaving `respawn` in its pane, in one daemon
    /// commit, whether or not it shows its tab bar (cx-v4dmy: every chat shows
    /// it by default). Without `respawn` (a New Tab page, which is not a daemon
    /// tab) it stays in `controller`.
    @MainActor static func route(from controller: PaneController, respawn: SplitRespawn?,
                                 services: AppServices) -> PaneController? {
        guard let content = controller.workspace else { return controller }
        // A chat with only New Tab pages beside it is still alone: it docks, and its pages follow it.
        let placement = resolve(from: controller, services: services, ignoringPages: true)
        switch placement {
        case .here:
            return controller
        case .tab(let target):
            guard let strip = content.panes[target] else { return controller }
            PaneHandlers.focus(target, in: content)
            return strip
        case .dockChat:
            guard let respawn, controller.daemon.supports(DaemonCapability.tabColumnRespawn.rawValue),
                  let chat = loneChat(in: controller.pane.tabs, isChat: { isChat($0, services: services) },
                                      isNewTabPage: { services.agentTabs.isNewTabPage($0.id) }) else { return controller }
            // The new tab left in the pane takes focus, not the docked chat (as AgentBesidePlacement).
            let source = controller.pane, pane = controller.layoutPaneID
            let originalSurfaces = Set(source.tabs.map(\.surface))
            let intent = content.beginFocusIntent()
            let pages = newTabPages(in: source.tabs) { services.agentTabs.isNewTabPage($0.id) }
            // main-hop-allow: the action's own tracked work (registry.track), not frame work: it awaits the daemon's dock
            // move, then the New Tab page moves, each bounded by AgentBesidePlacement.openLimit.
            services.registry.track(Task { @MainActor [weak content, weak controller] in
                let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    TabMoves.toNewDockColumn(chat, anchor: source, edge: .left, role: .agentChat,
                                             respawn: respawn, services: services) { done.resume(returning: $0) }
                }
                guard moved else { return "move-tab-to-column failed (see the app log)" }
                if let content {
                    await moveNewTabPages(pages, with: chat, from: source, in: content, services: services,
                                          generation: intent, whenDocked: { _ in
                        // Land focus as soon as the dock is listed, before optional page moves: on the
                        // respawned tab, else (not listed yet) on the pane it opens in.
                        if let respawned = source.tabs.first(where: { !originalSurfaces.contains($0.surface) }) {
                            content.expectFocus(on: respawned.surface, generation: intent)
                        } else {
                            PaneHandlers.focus(pane, in: content)
                        }
                    })
                }
                // A hidden tab bar was the chat's choice: the tab left in the pane shows its tab bar again.
                if let controller, services.paneTabBars.choice(for: controller.paneKey) == false {
                    services.paneTabBars.set(nil, for: controller.paneKey)
                    controller.apply(controller.snapshot())
                }
                return nil
            })
            return nil
        case .besideDock:
            openBesideDock(controller, respawn: respawn, services: services)
            return nil
        }
    }

    /// A person's new tab from Home's pinned dock alone (`pinned-dock-alone-v1`): a new column
    /// right of the dock holds it. A terminal is a new column with its shell, spawned with the
    /// tab's options (cwd, keep); a web page opens the way Home's links do (`workspace.open_url`,
    /// which makes the column right of a lone dock); the New Tab page is a split to the right,
    /// which the daemon makes a column beside the dock; any other address is a browser tab aimed
    /// at the dock, which the daemon makes in a new column right of it.
    @MainActor static func openBesideDock(_ controller: PaneController, respawn: SplitRespawn?, services: AppServices) {
        switch respawn {
        case .terminal(let spawn)?:
            controller.workspace?.newColumn(after: controller.layoutPaneID, options: spawn)
        case .browser(let url, _, _)? where URL(string: url).map(isWebPage) == true:
            let daemon = controller.daemon
            services.registry.track(Task { @MainActor in
                _ = await daemon.request("workspace.open_url") { try await WorkspaceOpenURLClient($0).openOnHome(url) }
                return nil
            })
        case .browser(let url, let engine, let profileID)? where !isNewTabAddress(url, services: services):
            // A browser tab aimed at the lone dock opens in a new column right of it (the daemon's
            // reroute, or PaneBrowserTabOpener's move while the dock takes tabs).
            controller.newBrowserTab(url: URL(string: url), engine: engine.rawValue, profile: profileID)
        case .browser?, nil:
            NewTabPage.split(controller, edge: .right)
        }
    }

    /// Whether `url` is a New Tab page address (the setting's page or an engine's own).
    @MainActor private static func isNewTabAddress(_ url: String, services: AppServices) -> Bool {
        [BrowserEngineChoice(engine: .cef), BrowserEngineChoice(engine: .webkit)].contains { services.newTabAddress(for: $0) == url }
    }

    private static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension ChatColumnPlacement {
    /// Joins the chat's new dock after its move is reported. The caller awaits this inside its
    /// tracked run; optional page moves cannot fail the tool open or move keyboard focus.
    @MainActor static func moveNewTabPages(_ pages: [TabModel], with chat: TabModel, from source: PaneModel,
                                           in content: WorkspaceContentController, services: AppServices,
                                           generation: UInt64, whenDocked: @MainActor (PaneModel) -> Void = { _ in }) async {
        let daemon = services.machines.daemon(forTab: chat)
        let machineID = daemon.machineID
        let appeared = await waitForDockUpdate(limit: AgentBesidePlacement.openLimit) {
            services.locateTab(chat.id, onMachine: machineID).map { $0.1 !== source } ?? false
        }
        guard appeared, let dock = services.locateTab(chat.id, onMachine: machineID)?.1 else {
            daemon.logger.error("chat dock: the moved chat's pane did not appear; New Tab pages stayed in their pane")
            return
        }
        await followNewTabPages(pages, start: generation, generation: { content.focus.currentState().generation }, isDockCurrent: {
            services.locateTab(chat.id, onMachine: machineID)?.1 === dock
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
            guard services.locateTab(page.id, onMachine: machineID)?.1 === source,
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
            guard settled, services.locateTab(page.id, onMachine: machineID)?.1 === dock else {
                daemon.logger.error("chat dock: a New Tab page's move was not reported in the dock")
                return false
            }
            return true
        }
    }
}
