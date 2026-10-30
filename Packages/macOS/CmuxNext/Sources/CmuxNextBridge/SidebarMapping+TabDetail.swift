import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// A listed tab row's facts (`SidebarTabLine`), mapped with its workspace's row, so drawing the row
/// computes nothing (after u9696, Lawrence's scratch/a-hover-tabs).
extension SidebarMapping {
    /// Fills `listed`'s status and facts from `tab`: its workspace's name, its own status, the program's
    /// status words, the agent, a page's host, the folder (`shorten`ed as the row's folder is), and whether
    /// that folder is the workspace's own (`rowFolder`), which the detail leaves out: on every tab it says
    /// nothing of one.
    static func describe(_ listed: inout SidebarTab, _ tab: TabModel, in workspace: WorkspaceModel, state: StatusIndicatorState,
                         rowFolder: String?, shorten: (String) -> String) {
        listed.workspaceName = workspace.displayName
        listed.state = state
        listed.words = StatusMapping.shared.detail(tab)
        listed.agent = tab.agentName
        if tab.kind == .browser { listed.host = tab.url.flatMap(host) }
        listed.folder = tab.cwd.flatMap { $0.isEmpty ? nil : shorten($0) }
        listed.sharesWorkspaceFolder = tab.cwd != nil && tab.cwd == rowFolder
    }

    /// A page address's host without a leading `www.`; nil for an address without one (the New Tab
    /// and blank pages, `file:`).
    static func host(_ address: String) -> String? {
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
