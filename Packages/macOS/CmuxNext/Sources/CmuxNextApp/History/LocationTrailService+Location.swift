import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Observation
import CmuxNextFocus

/// Where the user is, as a trail location, and whether a location can be focused now.
extension LocationTrailService {
    /// `anyTarget`: also when the keyboard is elsewhere (a page's origin).
    /// The tab is found in the window's own pane (no walk of every machine's tabs).
    func location(of state: FocusState, in controller: WindowController, anyTarget: Bool = false) -> HistoryLocation? {
        guard anyTarget || state.target.isPaneScoped || state.target.isSidebar, let pane = state.pane,
              let tabID = state.topology.pane(pane)?.selectedTab?.id, let shown = controller.content,
              shown.workspace.id == state.topology.workspace, let paneModel = shown.paneModel(key: pane),
              let tab = paneModel.tabs.first(where: { $0.id == tabID }) else { return nil }
        let daemon = services.daemon(for: paneModel)
        let workspace: WorkspaceModel? = shown.workspace
        let content: HistoryLocation.Content = switch tab.kind {
        case .pty: .terminal
        case .browser: .browser
        default: .other
        }
        let workspaceID = workspace?.id ?? state.topology.workspace ?? ""
        return HistoryLocation(
            key: .init(machine: daemon.machineID, tab: tab.id), window: controller.state.id, workspace: workspaceID,
            pane: paneModel.id, content: content, title: title(of: tab, in: workspace),
            workspaceTitle: workspace?.displayName, machineName: daemon.machineID == MachineRegistry.localID ? nil : daemon.machineID,
            url: tab.url, cwd: tab.cwd, isIncognito: services.windows.isIncognito(workspace: workspaceID))
    }

    /// A trail entry's name for `tab`: the tab strip's (`TabTitleResolver`: a chat's, page's or user-set name), never
    /// the `about:blank` a chat or page tab's record carries.
    func title(of tab: TabModel, in workspace: WorkspaceModel?) -> String {
        var titles = TabTitleResolver(services: services, workspace: workspace?.handle)
        if tab.agentSession != nil { titles.workspaceName = AgentChatTabTitle.workspaceName(workspace) }
        return titles.title(tab)
    }

    /// The current title of an entry's tab while it is open on its machine; nil for a top page or a closed tab.
    func liveTitle(_ location: HistoryLocation) -> String? {
        // On the entry's own machine: a forked tab id may also live on another one.
        guard location.page == nil, let (tab, pane) = services.locateTab(location.key.tab, onMachine: location.key.machine) else { return nil }
        return title(of: tab, in: services.daemon(for: pane).store.workspace(containing: pane.handle))
    }

    /// Whether the location's tab exists on a connected machine now.
    func isAvailable(_ location: HistoryLocation) -> Bool {
        if let page = location.page { return TopPageRoute(rawValue: page).map(hasPage) ?? false }
        return services.locateTab(location.key.tab, onMachine: location.key.machine) != nil
    }

    func hasPage(_ route: TopPageRoute) -> Bool {
        if case .page(let id) = route { return TopPages.provider(id, services: services) != nil }
        return true
    }
}
