import CmuxNextDaemon
import CmuxNextWindowRules

/// Where a relaunch's front window lands once the saved windows are restored (cmux-window-rules `launch::landing`).
/// Leo 2026-11-18: "fresh startup opening home is obv fine but if it's not first time and the user was on a workspace
/// and a tab, obv just take them there"; "ofc reopening home if they were prev on home is fine".
///
/// The front saved window says where the person was: its top page Home, or the home workspace, is Home; else its
/// workspace and the tab its focused pane showed. A workspace the daemon still has opens on that tab (a tab whose
/// process ended after a reboot is still that tab: the daemon relaunches it). A first launch lands through
/// `FirstWorkspaceLaunch`, and a saved workspace the daemon lacks lands on Home (the known exception).
@MainActor
struct RelaunchLanding {
    let manager: WindowManager

    /// Lands the front window of `records` (restored this launch).
    func land(_ records: [WindowRecord]) {
        let value = manager.registry.value
        guard let front = value.recency.first(where: { value.window($0)?.isOpen == true }),
              let record = records.first(where: { $0.id == front }), let controller = manager.controller(for: front),
              let last = lastFront(record) else { return }
        let services = manager.services
        var workspaceLive = false, standing = WindowRules.TabStanding.gone
        if case let .workspace(id, pane, tab) = last, let workspace = services.workspace(id: id) {
            workspaceLive = true
            let saved = pane.flatMap { pane in workspace.screens.lazy.flatMap(\.panes).first { $0.id == pane } }?.tabs.first { $0.id == tab }
            if let saved { standing = saved.dead || saved.relaunch != nil ? .ended : .live }
        }
        switch WindowRules().launchLanding(last: last, workspaceLive: workspaceLive, tab: standing) {
        case let .workspace(id, pane, tab)?:
            // The adopted record already shows it on that tab; only a window that shows another workspace moves.
            let state = controller.state
            guard state.workspaceID != id || controller.content?.workspace.id != id else { return }
            if let pane, let tab { state.selection.select(tab, in: pane) }
            manager.select(id, in: state)
            controller.showWorkspace(requested: id)
        case .home(why: "unknownWorkspace")?:
            // Nothing stands in for a workspace the daemon lacks: Home, once Home is listed (else the window's own fallback).
            if services.home.homeWorkspace != nil { AppActions.showHome(services) }
        default:
            return // Home last (the adopted record shows it), a first launch (`FirstWorkspaceLaunch`), or an FFI without the rule.
        }
    }

    /// Nil for a front window on another top page (Settings, History): it reopens on that page, as saved.
    private func lastFront(_ record: WindowRecord) -> WindowRules.LastFront? {
        if let page = record.page { return page == TopPageRoute.home.rawValue ? .home : nil }
        guard let id = record.workspaceKey?.rawValue else { return .nothing }
        if manager.services.workspace(id: id)?.isAnyHome == true { return .home }
        let pane = record.focusedPanes[id] ?? record.focusedPane
        return .workspace(id, pane: pane, tab: pane.flatMap { record.selectedTabs[$0] })
    }
}
