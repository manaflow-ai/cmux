import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextTabs

/// The App side of ``CloudChatFocus`` (cmux#57249): the facts of the tab a pane shows, and the open on the focused Cloud
/// chat's machine through ``CloudFrontedChats/openTool(_:chat:cwd:typing:services:)``, the chat header's route. Every
/// person's new terminal or browser that names no other place calls ``openOnCloud(_:pane:invocation:cwd:typing:services:)``
/// first: New Terminal / New Browser (the pane toolbar's buttons, keys, palette, menu bar), Split Right / Down / Left / Up,
/// Split Browser Right / Down and the New Tab page's picks.
extension CloudFrontedChats {
    /// The Cloud chat tab `tab` shows, if any: the chat a Mac tab shows in place, or a Cloud machine's own chat tab.
    static func cloudChat(shownBy tab: TabModel?, byPerson: Bool = true, namesPlace: Bool = false, services: AppServices) -> AgentTabKey? {
        let shown = tab.map { tab -> CloudChatFocus.Shown in
            let machine = services.machines.daemon(forTab: tab).machineID
            let front = services.agentTabs.frontedChats.front(of: AgentTabKey(machine: machine, key: tab.id))
            return CloudChatFocus.Shown(machine: machine, key: tab.id, fronts: front.map { ($0.machine, $0.key) },
                                        onCloud: services.machines.session(machine) != nil, isChat: tab.agentSession != nil)
        }
        guard case let .cloudChat(machine, key) = CloudChatFocus.resolve(byPerson: byPerson, namesPlace: namesPlace, shown: shown) else { return nil }
        return AgentTabKey(machine: machine, key: key)
    }

    /// The tab pane `pane` shows: its strip's selection when a window shows it, else the daemon's.
    static func shownTab(of pane: PaneModel, services: AppServices) -> TabModel? {
        if let controller = services.paneController(for: pane) { return controller.selectedTab }
        return pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex] : nil
    }

    /// Opens tool `kind` on the Cloud machine of the chat pane `pane` shows, for a person's open naming no other place:
    /// true once routed there (or refused, saying why), false to open as before. `cwd`: an explicit folder, else the
    /// chat's on its machine; `typing`: text a terminal types once made.
    static func openOnCloud(_ kind: RightColumnPlacement.Kind, pane: PaneModel, invocation: ActionInvocation, namesPlace: Bool = false,
                            cwd: String? = nil, typing: String? = nil, services: AppServices) -> Bool {
        // A tab the open names (the chat header's own split) decides, else the tab the pane shows.
        let named = invocation.target?.kind == .tab ? pane.tabs.first { $0.id == invocation.target?.id } : nil
        guard let chat = cloudChat(shownBy: named ?? shownTab(of: pane, services: services), byPerson: invocation.origin == .user,
                                   namesPlace: namesPlace || invocation.besideCaller, services: services) else { return false }
        return openOnCloud(kind, chat: chat, cwd: cwd, typing: typing, services: services)
    }

    /// Opens tool `kind` on Cloud chat `chat`'s machine; false when its route is the pane's own (a terminal of a chat in
    /// its machine's workspace already runs there).
    static func openOnCloud(_ kind: RightColumnPlacement.Kind, chat: AgentTabKey, cwd: String? = nil, typing: String? = nil, services: AppServices) -> Bool {
        let folder = cwd ?? services.agentTabs.terminalFolder(of: chat.key, machine: chat.machine, on: services.machines.session(chat.machine)?.daemon)
        if let override = services.agentTabs.frontedChats.openToolOverride { return override(kind, chat, folder, typing) ?? false }
        return openTool(kind, chat: chat, cwd: folder, typing: typing, services: services) ?? false
    }
}
