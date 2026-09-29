import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

/// Resolves what an action acts on: the invocation's target (context menu,
/// palette, CLI) or the active window's focus.
struct ActionScope {
    let services: AppServices
    let invocation: ActionInvocation

    var window: WindowController? { services.windows.active }

    /// Pane of the targeted tab or pane, else the focused pane.
    var pane: PaneController? {
        if let target = invocation.target ?? invocation["tab"]?.targetValue ?? invocation["pane"]?.targetValue {
            switch target.kind {
            case .tab:
                if let (_, pane) = services.locateTab(target.id) { return services.paneController(for: pane) }
            case .pane:
                for controller in services.windows.controllers {
                    if let pane = controller.content?.panes.values.first(where: { $0.paneKey == target.id }) { return pane }
                }
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
            return services.workspace(id: target.id)
        }
        return window?.state.workspaceID.flatMap(services.workspace(id:))
    }

    var tabGroupID: String? {
        if let target = invocation.target ?? invocation["group"]?.targetValue, target.kind == .tabGroup { return target.id }
        guard let tab, let group = tab.pane.stripModel.tab(tab.id)?.groupID else { return nil }
        return group.rawValue
    }
}
