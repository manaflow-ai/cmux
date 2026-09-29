import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon

/// Target resolution for browser, open-in, notification, agent, and cloud
/// handlers. Each throws an `ActionFailure` (reported through `refuse`)
/// instead of silently doing nothing; reasons are localized `HandlerStrings`.
extension AppActionContext {
    var daemon: DaemonService { services.daemon }

    /// The daemon connection.
    func requireConnection() throws -> DaemonConnection {
        guard let connection = daemon.connection else { throw ActionFailure(message: MiscHandlerStrings.daemonOffline) }
        return connection
    }

    /// The targeted (or focused) pane.
    func pane(_ invocation: ActionInvocation) throws -> PaneController {
        guard let pane = scope(invocation).pane else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        return pane
    }

    /// The targeted (or focused) pane's browser page.
    func page(_ invocation: ActionInvocation) throws -> BrowserEntry {
        guard case .browser(let entry) = scope(invocation).pane?.currentContent else {
            throw ActionFailure(message: MiscHandlerStrings.noBrowser)
        }
        return entry
    }

    /// The window to show `workspaceID` in: the active one, else a new one.
    @discardableResult
    func window(showing workspaceID: String) -> WindowController {
        if let active = services.windows.active {
            services.windows.show(workspaceID: workspaceID, in: active.state)
            return active
        }
        return services.windows.open(record: nil, workspaceID: workspaceID)
    }

    /// Shows `tab` in its workspace and pane and selects it.
    func reveal(_ located: LocatedTab) {
        let controller = window(showing: located.workspace.id)
        controller.state.selection.select(located.tab.id, in: located.pane.id)
        services.paneController(for: located.pane)?.select(StripTabID(located.tab.id))
    }

    /// Every tab in the mirror, workspace order then screen, pane, tab order.
    var allTabs: [LocatedTab] {
        var result: [LocatedTab] = []
        for workspace in daemon.store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    result += pane.tabs.map { LocatedTab(tab: $0, pane: pane, workspace: workspace) }
                }
            }
        }
        return result
    }
}

/// A tab located in the daemon mirror.
struct LocatedTab {
    let tab: TabModel
    let pane: PaneModel
    let workspace: WorkspaceModel
}
