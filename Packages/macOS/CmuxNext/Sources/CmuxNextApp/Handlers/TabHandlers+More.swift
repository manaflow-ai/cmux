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
            TabMoves.toNewSplit(tab, pane: pane, edge: edge, services: ctx.services) { ok in
                if !ok { ctx.services.restoreDetachedTab(tab.id) }
            }
        })
        registry.bind("tab.moveToNewColumn", invoke: { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            TabMoves.toNewColumn(tab, anchor: pane, services: ctx.services)
        })
        registry.bind("tab.moveToWorkspace", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), let workspace = ctx.workspaceArgument(invocation) else { return }
            TabMoves.toWorkspace(tab, workspace: workspace, services: ctx.services)
        })
        registry.bind("palette.moveTabToNewWorkspace", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), ctx.connection() != nil else { return }
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: ctx.services),
                      let state = ctx.services.windows.active?.state else { return }
                ctx.services.windows.show(workspaceID: key.rawValue, in: state)
            }
        })
        registry.bind("tab.moveToNewWindow", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation), ctx.connection() != nil else { return }
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: ctx.services) else { return }
                ctx.services.windows.open(record: nil, workspaceID: key.rawValue)
            }
        })
    }

    private static func bindTabState(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("palette.toggleTabUnread", unavailable: ctx.needs(DaemonCapabilities.notificationAck), invoke: { invocation in
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
            let workspace = ctx.services.daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
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
