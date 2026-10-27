public import CmuxNextDaemon
import Foundation

/// Reads a workspace for its sidebar row from daemon values alone: the tab the row stands for, the
/// work a page yields its name to, its agent and chat tabs, folders and status entries. The row
/// itself (sidebar models, icons, colors) is CmuxNextBridgeUI's `SidebarMapping` extension, so the
/// rules a workspace's name follows (CmuxNextWorkspaceNaming) build without the sidebar UI.
public struct SidebarMapping {
    public static let shared = Self()
    /// The workspace kind of the home workspace (`workspace-kind-v1`).
    public static let homeKind = "home"

    /// Nobody named `workspace` and nothing names it: no title, the daemon's default name, and
    /// no name from its front tab (`label`, the auto name) beyond the home folder (Leo 2026-10-20:
    /// "~", "workspace-11" and "workspace-29" rows clutter the sidebar).
    public static func isUnnamed(_ workspace: WorkspaceModel, label: String?) -> Bool {
        guard workspace.isUnnamed else { return false }
        guard let label, !label.isEmpty else { return true }
        return label == "~"
    }

    /// The tab the row stands for: the selected tab of the workspace's most
    /// recently focused pane; nil for a workspace with no tabs.
    public func frontTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        let panes = workspace.screens.flatMap(\.panes).filter { !$0.tabs.isEmpty }
        guard let pane = panes.max(by: { $0.focusedAt < $1.focusedAt }) else { return nil }
        return selected(pane, selectedTab: selectedTab)
    }

    /// The tab a browser front tab yields its row's name to (a PR opened in
    /// a split, https://github.com/manaflow-ai/cmux/issues/22249): the
    /// selected tab of the most recently focused pane that shows a chat or
    /// terminal, the work the row was named for before the page opened; nil
    /// while every pane shows a page. A Home, page or app tab gives no name
    /// (`WorkspaceAutoNameReader.front`), so it is passed over too.
    public func workTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        // One pass: the newest eligible pane, the first stored one on a tie (as `frontTab`).
        var work: (tab: TabModel, focusedAt: UInt64)?
        for screen in workspace.screens {
            for pane in screen.panes where !pane.tabs.isEmpty {
                if let work, pane.focusedAt <= work.focusedAt { continue }
                let tab = selected(pane, selectedTab: selectedTab)
                let named = tab.agentSession != nil || (tab.kind != .conversation && tab.page == nil && tab.appTab == nil)
                if tab.kind != .browser, named { work = (tab, pane.focusedAt) }
            }
        }
        return work?.tab
    }

    /// The tab `pane` shows: the window's selection, else the daemon's default tab.
    private func selected(_ pane: PaneModel, selectedTab: (PaneModel) -> String?) -> TabModel {
        if let id = selectedTab(pane), let tab = pane.tabs.first(where: { $0.id == id }) { return tab }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)]
    }

    /// The brand of the agent running in these tabs (design/agent-icons): the first that
    /// works or waits, else the first live one.
    package func agentBrand(_ tabs: [TabModel]) -> String? {
        agentTab(tabs)?.agentBrand
    }

    /// The tab whose unread notification is the newest (daemon ids grow).
    package func newestUnread(_ tabs: [TabModel]) -> TabModel? {
        tabs.filter(\.hasUnread).max { ($0.notification?.notification.rawValue ?? 0) < ($1.notification?.notification.rawValue ?? 0) }
    }

    /// The last message of the row's agent chat (`chatTab`).
    package func lastMessage(_ front: TabModel?, _ tabs: [TabModel]) -> String? {
        chatTab(front, tabs)?.agentSession.flatMap(AgentTurnStateStore.shared.lastMessage(for:))
    }

    /// The row's agent chat, whose last message the row shows: the front tab's, else the first chat tab's.
    package func chatTab(_ front: TabModel?, _ tabs: [TabModel]) -> TabModel? {
        front?.agentSession != nil ? front : tabs.first { $0.agentSession != nil }
    }

    /// The agent chat a workspace's row shows (Copy Agent Identifier on the row copies its id).
    public func rowChat(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        chatTab(frontTab(workspace, selectedTab: selectedTab), workspace.screens.flatMap(\.panes).flatMap(\.tabs))
    }

    /// The tab whose agent the row names: a working or waiting one first.
    package func agentTab(_ tabs: [TabModel]) -> TabModel? {
        let branded = tabs.lazy.filter { $0.agentBrand != nil }
        return branded.first { $0.agent?.state == .working || $0.agent?.state == .blocked } ?? branded.first
    }

    /// Status entry keys that feed their own row elements, not the status
    /// line (`cmux workspace status set ports|pr <text>`).
    public static let portsKey = "ports"
    public static let pullRequestKey = "pr"

    /// The status line: every entry but the ones other elements show.
    package static func statusLine(_ entries: [WorkspaceStatus.Entry]) -> String? {
        let texts = entries.filter { $0.key != portsKey && $0.key != pullRequestKey }.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    package static func entry(_ key: String, in entries: [WorkspaceStatus.Entry]) -> String? {
        entries.first { $0.key == key && !$0.text.isEmpty }?.text
    }

    /// The first tab that reports a folder: the row's folder and branch.
    package func folderTab(_ tabs: [TabModel]) -> TabModel? {
        tabs.first { $0.cwd != nil }
    }

    /// The front terminal's program as the shell or program titles it (OSC
    /// 0/2); nil for other tabs, an untitled terminal, or a title that only
    /// repeats the folder.
    package func process(_ tab: TabModel?) -> String? {
        guard let tab, tab.kind == .pty, tab.agent == nil else { return nil }
        let title = tab.titleText.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        if let cwd = tab.cwd, title == cwd || title == abbreviate(cwd) { return nil }
        return title
    }

    /// The newest agent update or notification of the tabs; nil without one.
    package func lastActivity(_ tabs: [TabModel]) -> Date? {
        let newest = tabs.map { max($0.agent?.updatedAtMs ?? 0, $0.notification?.createdAtMs ?? 0) }.max() ?? 0
        return newest == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(newest) / 1000)
    }

    /// A folder of another computer (SSH, Cloud) as its shell prompt writes it: its account's
    /// home (`/Users/<name>` or `/home/<name>`) as `~`. The app does not know that machine's home
    /// otherwise, and this Mac's home says nothing about it (cx-gaq9).
    public static func abbreviateRemote(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home", !parts[2].isEmpty,
              parts[2] != "Shared" else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    package func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
