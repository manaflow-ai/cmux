import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

// Tab moves out of the pane (split, column, workspace, window), unread
// state, per-kind tab verbs, and identifier copies.
extension TabHandlers {
    static func bindMoreActions(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindLayoutMoves(registry, ctx)
        bindTabState(registry, ctx)
        bindIdentifiers(registry, ctx)
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
            let reveal = revealer(ctx, tab: tab, outcome: .newSplit(paneID: pane.id, edge: .right), workspaceID: nil)
            TabMoves.toNewSplit(tab, pane: pane, edge: edge, services: ctx.services) { ok in
                if !ok { ctx.services.restoreDetachedTab(tab.id) }
                reveal(ok)
            }
        })
        registry.bind("tab.moveToNewColumn", invoke: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let reveal = revealer(ctx, tab: tab, outcome: .newColumn(screenID: "", afterColumnID: ""), workspaceID: nil)
            TabMoves.toNewColumn(tab, anchor: pane, services: ctx.services, completion: reveal)
        })
        registry.bind("tab.moveToWorkspace", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), let workspace = ctx.workspaceArgument(invocation) else { return }
            let reveal = revealer(ctx, tab: tab, outcome: .workspace(id: workspace.id), workspaceID: workspace.id)
            TabMoves.toWorkspace(tab, workspace: workspace, services: ctx.services, completion: reveal)
        })
        registry.bind("palette.moveTabToNewWorkspace", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), ctx.connection() != nil else { return }
            let windows = ctx.services.windows!
            let origin = windows.moveOrigin(of: ctx.services.workspaceID(ofTab: tab.id))
            // Read before the await: whether this run may change the view,
            // and the window it acts in.
            let allowed = ViewChangePolicy.allowed()
            let source = ctx.services.landingWindow(tab: tab.id, workspaceID: nil)
            let preferred = (source ?? windows.active)?.state
            if allowed, let source, let pane = ctx.services.locateTab(tab.id)?.1 { source.focus.followMovedTab(tab.id, from: pane.id) }
            ctx.registry.track(Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: ctx.services) else {
                    return "move-tab-to-new-workspace failed (see the app log)"
                }
                windows.placeMoved(key.rawValue, from: origin, preferred: preferred, newWindow: false, select: allowed)
                return nil
            })
        })
        registry.bind("tab.moveToNewWindow", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), ctx.connection() != nil else { return }
            let windows = ctx.services.windows!
            let origin = windows.moveOrigin(of: ctx.services.workspaceID(ofTab: tab.id))
            // Read before the await: a run this client's user did not start
            // opens the window behind, never key.
            let allowed = ViewChangePolicy.allowed()
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: ctx.services) else { return }
                windows.placeMoved(key.rawValue, from: origin, preferred: nil, newWindow: true, select: allowed)
            }
        })
    }

    private static func bindTabState(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("palette.toggleTabUnread", unavailable: ctx.needs(DaemonCapabilities.shared.notificationAck), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard tab.hasUnread else { return ctx.refuse(RefusalStrings.markUnreadUnsupported("tab-mark-unread")) }
            let surface = tab.surface
            ctx.send("ack-tab-notifications") { _ = try await $0.acknowledgeNotifications(of: surface) }
        })
        registry.bind("reloadTab", invoke: { invocation in
            guard let (_, content) = ctx.visibleContent(invocation) else { return }
            guard case .browser(let entry) = content else {
                return ctx.refuse(RefusalStrings.terminalCannotReload)
            }
            entry.chrome.perform(.reload)
        })
        registry.bindUnavailable("palette.toggleFullWidthTab", reason: RefusalStrings.fullWidthTabUnported)
        registry.bindUnavailable("toggleTabAudioMute", reason: RefusalStrings.audioMuteUnported)
        registry.bindUnavailable("disconnectRemoteTab", reason: RefusalStrings.needsDaemonCapability("remote-ssh-tabs"))
    }

    private static func bindIdentifiers(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("palette.copyIdentifiers", invoke: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            let workspace = ctx.services.activeDaemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
            var lines: [String] = []
            if let workspace { lines.append("workspace_id=\(workspace.id)") }
            lines.append("pane_id=\(pane.id)")
            lines.append("surface_id=\(tab.id)")
            copy(lines.joined(separator: "\n"))
        })
        registry.bind("palette.copyPaneID", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            copy("pane_id=\(pane.id)")
        })
        registry.bind("palette.copySurfaceID", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            copy("surface_id=\(tab.id)")
        })
        let noLinks = RefusalStrings.deepLinksUnported
        registry.bindUnavailable("palette.copyPaneLink", reason: noLinks)
        registry.bindUnavailable("palette.copySurfaceLink", reason: noLinks)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension TabHandlers {
    /// The view change after a tab move an action started, captured before
    /// any await (`ViewChangePolicy.allowed()`, the landing window): focus follows
    /// the tab into the window that will show it (an expectation set now,
    /// so a newer user choice wins), and the returned closure, called with
    /// whether the move landed, shows the workspace and makes the window
    /// key once the store holds the result. A run this client's user did
    /// not start changes nothing.
    @MainActor
    static func revealer(_ ctx: AppActionContext, tab: TabModel, outcome: TabDragOutcome,
                         workspaceID: String?) -> @MainActor (Bool) -> Void {
        let services = ctx.services
        let allowed = ViewChangePolicy.allowed()
        let source = services.landingWindow(tab: tab.id, workspaceID: nil)
        let landing = services.landingWindow(tab: tab.id, workspaceID: workspaceID) ?? source
        if allowed, let landing, let pane = services.locateTab(tab.id)?.1 { landing.focus.followMovedTab(tab.id, from: pane.id) }
        let daemon = services.machines.daemon(forTab: tab)
        return { landed in
            guard let reveal = services.actionReveal(outcome, allowed: allowed, landed: landed, window: landing, source: source) else { return }
            // After the store holds the result, like a drop.
            daemon.whenApplied(.generate()) { services.applyReveal(reveal, workspaceID: workspaceID, fallback: landing) }
        }
    }
}
