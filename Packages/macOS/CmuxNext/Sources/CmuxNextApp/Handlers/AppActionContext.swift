import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextBridge

/// What handler files reach: app services, target resolution, and typed
/// results. Each `Handlers/<Domain>Handlers.swift` exposes
/// `static func bind(into registry: ActionRegistry, context: AppActionContext)`
/// and is called once from `AppActions.bind`.
///
/// Handlers never no-op silently: a handler that cannot act calls `fail`
/// (reported as `failed: <reason>` on the control socket), and an action
/// this build cannot run at all is bound with `unavailable` (reported as
/// `unavailable: <reason>`, shown disabled in the palette).
struct AppActionContext {
    let services: AppServices

    var registry: ActionRegistry { services.registry }
    var daemon: DaemonService { services.daemon }

    func scope(_ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }

    /// Reports why the running handler did nothing.
    func fail(_ reason: String) {
        registry.fail(reason)
    }

    /// Binds every ID in `ids` as unavailable in this build.
    func unavailable(_ ids: [ActionID], _ reason: String) {
        for id in ids {
            let bound = registry.bindUnavailable(id, reason: reason)
            assert(bound, "\(id) is not in the action catalog")
        }
    }

    /// The daemon connection, or a reported failure.
    func connection() -> DaemonConnection? {
        guard let connection = daemon.connection else {
            fail(HandlerStrings.daemonOffline)
            return nil
        }
        return connection
    }

    /// The window to show things in: the active one, else a new one.
    func window(showing workspaceID: String) -> WindowController {
        if let active = services.windows.active {
            services.windows.show(workspaceID: workspaceID, in: active.state)
            return active
        }
        return services.windows.open(record: nil, workspaceID: workspaceID)
    }

    /// Shows `tab` in its workspace and pane and focuses it.
    func reveal(tab: TabModel, pane: PaneModel, workspace: WorkspaceModel) {
        let controller = window(showing: workspace.id)
        controller.state.selection.select(tab.id, in: pane.id)
        services.paneController(for: pane)?.select(StripTabID(tab.id))
    }
}

/// A tab located in the daemon mirror.
struct LocatedTab {
    let tab: TabModel
    let pane: PaneModel
    let workspace: WorkspaceModel
}

extension AppActionContext {
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
