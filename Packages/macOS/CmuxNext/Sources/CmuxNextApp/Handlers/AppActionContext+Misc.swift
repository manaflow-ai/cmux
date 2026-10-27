import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextBrowser
import CmuxNextDaemon

/// Target resolution for browser, open-in, notification, agent, and cloud
/// handlers. Each throws an `ActionFailure` (reported through `refuse`)
/// instead of silently doing nothing; reasons are localized `HandlerStrings`.
extension AppActionContext {
    var daemon: DaemonService { services.activeDaemon }

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

    /// The targeted (or focused) pane's browser page. A tab target whose
    /// page is on screen is that page itself: a press on its own toolbar
    /// (Downloads, More, profile, media) names its tab, and the pane's
    /// selected content is not always that page (a pane shown in two
    /// windows resolves to the first one's controller, an adopted Web Store
    /// tab), which refused the press with "No browser tab is focused."
    func page(_ invocation: ActionInvocation) throws -> BrowserEntry {
        if let target = invocation.target, target.kind == .tab,
           let entry = services.cache.existingBrowser(target.id), entry.chrome.window != nil {
            return entry
        }
        guard case .browser(let entry) = scope(invocation).pane?.currentContent else {
            throw ActionFailure(message: MiscHandlerStrings.noBrowser)
        }
        return entry
    }

    /// The window showing `workspaceID`: the one that lists it, else the
    /// active one (which takes it), else a new one.
    @discardableResult
    func window(showing workspaceID: String) -> WindowController? {
        services.windows.reveal(workspaceID: workspaceID)
    }

    /// Shows `tab` in its workspace and pane and selects it.
    /// Nothing when the run may not change this client's view.
    func reveal(_ located: LocatedTab) {
        guard ActionRunScope.viewChangeAllowed(), let controller = window(showing: located.workspace.id) else { return }
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
