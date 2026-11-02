import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import enum CmuxNextLayout.ChatColumnPlacement

// Tab moves out of the pane (split, column, workspace, window), unread
// state, per-kind tab verbs, and identifier copies (links: LinkHandlers).
extension TabHandlers {
    static func bindMoreActions(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindLayoutMoves(registry, ctx)
        bindTabState(registry, ctx)
        bindIdentifiers(into: registry, context: ctx)
    }

    private static func bindLayoutMoves(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("tab.moveToNewSplit", invoke: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let edge: PaneEdge = switch invocation["direction"]?.stringValue {
            case "left": .left
            case "up": .top
            case "down": .bottom
            default: .right
            }
            let keepFocus = invocation["keep_focus"]?.boolValue == true
            // The chat dock never splits (ChatDockRules): a chat moved out of it to its right, when the
            // dock keeps another tab, gets a new column right after the dock, so a docked chat's
            // subagents open beside it. A lone docked chat is still refused (the dock would close).
            if edge == .right, pane.tabs.count > 1, ChatDockRules.isChatDock(pane, services: ctx.services),
               ChatColumnPlacement.isChat(tab, services: ctx.services), let dock = ctx.services.columnHandle(containing: pane) {
                let reveal = revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
                return TabMoves.toNewColumn(tab, anchor: pane, afterColumn: dock, services: ctx.services, keepFocus: keepFocus) { ok in
                    if !ok { ctx.services.restoreDetachedTab(tab.id) }
                    reveal(ok)
                }
            }
            let reveal = revealer(ctx, tab: tab, outcome: .newSplit(paneID: pane.id, edge: .right), workspaceID: nil)
            TabMoves.toNewSplit(tab, pane: pane, edge: edge, services: ctx.services, keepFocus: keepFocus) { ok in
                if !ok { ctx.services.restoreDetachedTab(tab.id) }
                reveal(ok)
            }
        })
        registry.bind("tab.moveToNewColumn", invoke: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let reveal = revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewColumn(tab, anchor: pane, services: ctx.services, keepFocus: invocation["keep_focus"]?.boolValue == true, completion: reveal)
        })
        registry.bind("tab.moveToWorkspace", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), let workspace = ctx.workspaceArgument(invocation) else { return }
            let reveal = revealer(ctx, tab: tab, outcome: .workspace(id: workspace.id), workspaceID: workspace.id)
            TabMoves.toWorkspace(tab, workspace: workspace, services: ctx.services, completion: reveal)
        })
        registry.bindEffect("tab.moveToSpace", requires: DaemonCapability.profiles.rawValue,
                            daemon: ctx.services.machines.local, effect: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return .done }
            guard let room = try ctx.optionalRoom(invocation["space"]) else { return .refused(RoomStrings.roomArgumentRequired) }
            return moveToSpace(ctx, tab: tab, room: room.id)
        })
        registry.bind("palette.moveTabToNewWorkspace", invoke: { moveToNewWorkspace(ctx, $0, newWindow: false) })
        registry.bind("tab.moveToNewWindow", invoke: { moveToNewWorkspace(ctx, $0, newWindow: true) })
    }

    /// Move Tab to Space moves only the tab: a tab alone in its workspace takes that workspace (a pin in the home
    /// session, as Move Workspace to Space), one with siblings moves to a new workspace pinned to the space.
    private static func moveToSpace(_ ctx: AppActionContext, tab: TabModel, room: ProfileID) -> ActionEffect {
        let services = ctx.services, home = services.machines.local
        guard let id = services.workspaceID(ofTab: tab), let workspace = services.workspace(id: id),
              let qualified = WindowProfiles.qualified(id, machines: services.machines) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
        if WindowProfiles.membership(services.machines)?.pinned(qualified) == room { return .refused(RoomStrings.alreadyInRoom) }
        if let reason = TabPromotion.refusal(tab: tab, services: services) { return .refused(reason) }
        let alone = workspace.screens.flatMap(\.panes).flatMap(\.tabs).count == 1, session = qualified.session
        // action-wait-allow: a space pin has no store intent (Move Workspace to Space sends it the same way), so nothing local stands in.
        return .waiting(.daemonEcho) {
            var key: WorkspaceKey? = WorkspaceKey(rawValue: qualified.key)
            if !alone { key = await TabMoves.toNewWorkspace(tab, services: services) }
            guard let key else { return "move-tab-to-new-workspace failed (see the app log)" }
            return await home.failure("pin-workspace") { try await $0.pinWorkspace(session: session, key: key, to: room) }
        }
    }

    /// Move Tab to New Workspace, or to a New Window that shows the new workspace. On one of several
    /// selected tabs every selected tab goes, in strip order (`movingTabs`).
    private static func moveToNewWorkspace(_ ctx: AppActionContext, _ invocation: ActionInvocation, newWindow: Bool) {
        guard let (tab, _) = ctx.daemonTab(invocation), ctx.connection() != nil else { return }
        if let reason = TabPromotion.refusal(tab: tab, services: ctx.services) {
            return ctx.registry.refuse(reason)
        }
        let windows = ctx.services.windows, tabs = ctx.movingTabs(invocation, tab)
        let origin = windows.moveOrigin(of: ctx.services.workspaceID(ofTab: tab))
        // Read before the await: whether this run may change the view (a run this client's user did
        // not start opens the window behind, never key), and the window it acts in.
        let allowed = ActionRunScope.viewChangeAllowed()
        let source = newWindow ? nil : ctx.services.landingWindow(tabWorkspace: ctx.services.workspaceID(ofTab: tab), workspaceID: nil)
        let preferred = newWindow ? nil : (source ?? windows.active)?.state
        if allowed, let source, let pane = ctx.services.locateTab(model: tab)?.1 { source.focus.followMovedTab(tab.id, from: pane.id) }
        let work: ActionWork = Task {
            guard let key = await TabMoves.toNewWorkspace(tabs.first ?? tab, services: ctx.services) else {
                return "move-tab-to-new-workspace failed (see the app log)"
            }
            await TabMoves.join(tabs.dropFirst(), workspace: key, services: ctx.services)
            windows.placeMoved(key.rawValue, from: origin, preferred: preferred, newWindow: newWindow, select: allowed)
            return nil
        }
        if !newWindow { ctx.registry.track(work) }
    }

    private static func bindTabState(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        // Mark Tab Unread on any tab (`tab-mark-unread-v1`); an unread tab is read instead.
        registry.bind("palette.toggleTabUnread", run: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            // A read agent chat: acpmux marks it unread until it is shown again (cx-ncc.78), as the chat menu's row does.
            if !tab.showsUnread, tab.agentSession != nil, let view = ctx.services.agentTabs.existingView(tab.id) {
                let daemon = ctx.services.daemon(for: pane)
                let mark = AgentChatMarkUnread(acpmux: { await AgentPaneMarkUnread(view.model).run() },
                                               daemon: { try TabUnreadMark.set(true, tab: tab, daemon: daemon) })
                // task-owner: one mark; ends when acpmux or the daemon answers
                Task {
                    do { try await mark.run() } catch { ctx.refuse((error as? ActionFailure)?.message ?? RefusalStrings.describe(error)) }
                }
                return
            }
            try TabUnreadMark.toggle(tab, pane: pane, context: ctx)
        })
        registry.bind("reloadTab", invoke: { invocation in
            guard let (_, content) = ctx.visibleContent(invocation) else { return }
            guard case .browser(let entry) = content else {
                return ctx.refuse(RefusalStrings.terminalCannotReload)
            }
            entry.chrome.perform(.reload)
        })
        // Full Width Tab: the pane's strip shows only the selected tab, across the strip (PaneFullWidthTabs).
        registry.bind("palette.toggleFullWidthTab", invoke: { invocation in
            guard let (pane, id) = ctx.tab(invocation) else { return }
            pane.toggleFullWidthTab(showing: id)
        })
        bindAudio(registry, ctx)
    }

    /// The mute actions (`BrowserTabAudio`): the strip's and the sidebar row's speakers run the toggles.
    private static func bindAudio(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind(BrowserTabAudio.toggleActionID, invoke: { BrowserTabAudio.toggleMute(ctx, $0) })
        ActionTargetTitles.set(BrowserTabAudio.toggleActionID, in: registry) { [weak registry] invocation in
            registry.flatMap { BrowserTabAudio.targetTitle($0, ctx.services.cache, invocation) }
        }
        registry.bind("tab.muteAudio", invoke: { BrowserTabAudio.setMuted(true, ctx, $0) })
        registry.bind("tab.unmuteAudio", invoke: { BrowserTabAudio.setMuted(false, ctx, $0) })
        registry.bind("tab.muteOtherAudio", invoke: { BrowserTabAudio.muteOthers(ctx, $0) })
        registry.bind(BrowserTabAudio.workspaceToggleActionID, run: { invocation in
            try BrowserTabAudio.toggleWorkspaces(WindowMembershipHandlers.rowTargets(invocation, ctx), cache: ctx.services.cache)
        })
    }
}

extension TabHandlers {
    /// The view change after a tab move an action started, captured before
    /// any await (`ActionRunScope.viewChangeAllowed()`, the landing window): focus follows
    /// the tab into the window that will show it (an expectation set now,
    /// so a newer user choice wins), and the returned closure, called with
    /// whether the move landed, shows the workspace and makes the window
    /// key once the store holds the result. A run this client's user did
    /// not start changes nothing.
    @MainActor
    static func revealer(_ ctx: AppActionContext, tab: TabModel, outcome: TabDragOutcome,
                         workspaceID: String?) -> @MainActor (Bool) -> Void {
        let services = ctx.services
        let allowed = ActionRunScope.viewChangeAllowed()
        let source = services.landingWindow(tabWorkspace: services.workspaceID(ofTab: tab), workspaceID: nil)
        let landing = services.landingWindow(tabWorkspace: services.workspaceID(ofTab: tab), workspaceID: workspaceID) ?? source
        if allowed, let landing, let pane = services.locateTab(model: tab)?.1 { landing.focus.followMovedTab(tab.id, from: pane.id) }
        let daemon = services.machines.daemon(forTab: tab)
        return { landed in
            guard let reveal = services.actionReveal(outcome, allowed: allowed, landed: landed, window: landing, source: source) else { return }
            // After the store holds the result, like a drop.
            daemon.whenApplied(.generate()) { services.applyReveal(reveal, workspaceID: workspaceID, fallback: landing) }
        }
    }
}

/// Copy Workspace ID, Copy Pane ID, Copy Tab ID and Copy IDs (#27709, classic parity): the
/// workspace row menu, the pane and tab menus, the terminal's right-click menu and the palette.
/// The text is classic's (`WorkspaceSurfaceIdentifierClipboardText`: `key=value` lines, one
/// block per workspace) with the public ids the CLI resolves (`PublicIDTargetResolver`):
/// `ws_…`, `pane_…`, `tab_…`, never a workspace's durable key.
extension TabHandlers {
    /// `copy` writes the text (default the general pasteboard, `context.copy`).
    static func bindIdentifiers(into registry: ActionRegistry, context: AppActionContext, copy: (@MainActor (String) -> Void)? = nil) {
        let copy = copy ?? { context.copy($0) }
        // Every selected row, as classic's Copy Workspace IDs.
        registry.bindEffect("palette.copyWorkspaceID", requires: nil, effect: { invocation in
            copy(workspaceIDText(try WindowMembershipHandlers.rowTargets(invocation, context), refs: false))
            return .done
        })
        registry.bindEffect("palette.copyWorkspaceIDAndRef", requires: nil, effect: { invocation in
            copy(workspaceIDText(try WindowMembershipHandlers.rowTargets(invocation, context), refs: true))
            return .done
        })
        // The context helpers report a missing pane or tab themselves.
        registry.bindEffect("palette.copyPaneID", requires: nil, effect: { invocation in
            if let pane = context.daemonPane(invocation) { copy("pane_id=\(pane.id)") }
            return .done
        })
        registry.bindEffect("palette.copySurfaceID", requires: nil, effect: { invocation in
            if let (tab, _) = context.daemonTab(invocation) { copy("surface_id=\(tab.id)") }
            return .done
        })
        registry.bindEffect("palette.copyIdentifiers", requires: nil, effect: { invocation in
            guard let (tab, pane) = context.daemonTab(invocation) else { return .done }
            let workspace = context.services.daemon(for: pane).store.workspace(containing: pane.handle)
            copy(((workspace.map { ["workspace_id=\(publicID($0))"] } ?? []) + ["pane_id=\(pane.id)", "surface_id=\(tab.id)"]).joined(separator: "\n"))
            return .done
        })
    }

    /// The id `cmux … --workspace` and `--target workspace:` accept: the resource id on registry daemons.
    private static func publicID(_ workspace: WorkspaceModel) -> String { workspace.resourceID?.rawValue ?? workspace.id }

    /// One block per workspace, a blank line between them; with `refs`, each block leads with its `--target` form.
    private static func workspaceIDText(_ workspaces: [WorkspaceModel], refs: Bool) -> String {
        workspaces.map { workspace in
            let id = publicID(workspace)
            return ((refs ? ["workspace_ref=\(ActionTargetRef(kind: .workspace, id: id))"] : []) + ["workspace_id=\(id)"]).joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
