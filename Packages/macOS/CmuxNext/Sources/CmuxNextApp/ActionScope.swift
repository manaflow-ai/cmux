import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

/// Resolves what an action acts on: the invocation's target (context menu,
/// palette, CLI) or the active window's focus. An explicit target that
/// names nothing resolves to nil and is refused as not found; it never
/// falls back to the focused object.
struct ActionScope {
    let services: AppServices
    let invocation: ActionInvocation

    var window: WindowController? { services.windows.active }

    /// Pane of the targeted tab or pane, else the focused pane.
    var pane: PaneController? {
        if let target = invocation.target ?? invocation["tab"]?.targetValue ?? invocation["pane"]?.targetValue {
            switch target.kind {
            case .tab:
                guard let (_, pane) = services.locateTab(target.id) else { return notFound(RefusalStrings.noTab(target.id)) }
                // In a hidden or parked workspace: no controller to act on.
                guard let controller = services.paneController(for: pane) else {
                    services.registry.refuse(RefusalStrings.notShownInAnyWindow(target.description))
                    return nil
                }
                return controller
            case .pane:
                for controller in services.windows.controllers {
                    if let pane = controller.content?.panes.values.first(where: { $0.paneKey == target.id }) { return pane }
                }
                return notFound(RefusalStrings.noPaneID(target.id))
            default: break
            }
        }
        return window?.focusedPane
    }

    /// The targeted tab, else the focused pane's selected tab.
    var tab: (pane: PaneController, id: StripTabID)? {
        if let target = invocation.target ?? invocation["tab"]?.targetValue, target.kind == .tab,
           let pane { return (pane, StripTabID(target.id)) }
        guard let pane, let id = pane.stripModel.selectedID else { return nil }
        return (pane, id)
    }

    var workspace: WorkspaceModel? {
        if let target = invocation.target ?? invocation["workspace"]?.targetValue, target.kind == .workspace {
            return services.workspace(id: target.id) ?? notFound(RefusalStrings.noWorkspace(target.id))
        }
        return window?.state.workspaceID.flatMap(services.workspace(id:))
    }

    private func notFound<T>(_ reason: String) -> T? {
        services.registry.refuseNotFound(reason)
        return nil
    }

    var tabGroupID: String? {
        if let target = invocation.target ?? invocation["group"]?.targetValue, target.kind == .tabGroup { return target.id }
        guard let tab, let group = tab.pane.stripModel.tab(tab.id)?.groupID else { return nil }
        return group.rawValue
    }
}
