import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextMacScreen
import CmuxNextSettings

extension AppServices: MenuBarExtraHost {
    var menuBarAccount: MenuBarMenuState.Account? { SidebarAccount(cloud.auth)?.menuBarAccount }
    var menuBarAvatar: NSImage? { SidebarAccount(cloud.auth)?.avatar.image(diameter: 16) }
    var menuBarAgentsWorking: Int { AgentNeedsInputJump.workingCount(AgentNeedsInputJump.tabs(of: daemon.store)) }
    var menuBarAgentsNeedingInput: Int { AgentNeedsInputJump.targets(chats: .app, tabs: AgentNeedsInputJump.tabs(of: daemon.store)).count }
    var menuBarUpdateReady: Bool { updater.indicatorPhase.isReady }
    var menuBarShowsGlobalKey: Bool { settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyDefault }

    var menuBarComputerUseAvailable: Bool { onboarding.computerUseSetup.phase == .ready }
    var menuBarComputerUseSessions: [MenuBarMenuState.ComputerUse.Session] { cmuxRemote.computerUse.menuBarSessions() }
    var menuBarUnread: [MenuBarMenuState.Chat] { AgentPriorityChats.app.menuBarChats(running: false) }
    var menuBarRunning: [MenuBarMenuState.Chat] { AgentPriorityChats.app.menuBarChats(running: true) }
    func menuBarChatImage(_ chat: MenuBarMenuState.Chat) -> NSImage? { AgentPriorityChats.menuBarImage(harness: chat.harness) }
    func menuBarResumeComputerUse(_ session: String) { cmuxRemote.sendComputerUseSession(.resume, session: session) }
    func menuBarShowComputerUseCursor(_ session: String) { cmuxRemote.sendComputerUseSession(.spotlight, session: session) }
    func menuBarOpenChat(_ id: String) { if let lane = AgentPriorityChats.app.lane(id) { SidebarPriorityFeed.open(lane, services: self) } }
}
