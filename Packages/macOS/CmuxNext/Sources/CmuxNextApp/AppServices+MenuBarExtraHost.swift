import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextComputerUse
import CmuxNextSettings

extension AppServices: MenuBarExtraHost {
    var menuBarAccount: MenuBarMenuState.Account? { SidebarAccount(cloud.auth)?.menuBarAccount }
    var menuBarAvatar: NSImage? { SidebarAccount(cloud.auth)?.avatar.image(diameter: 16) }
    var menuBarAgentsWorking: Int { AgentNeedsInputJump.workingCount(AgentNeedsInputJump.tabs(of: daemon.store)) }
    var menuBarAgentsNeedingInput: Int { AgentNeedsInputJump.targets(chats: .app, tabs: AgentNeedsInputJump.tabs(of: daemon.store)).count }
    var menuBarUpdateReady: Bool { updater.indicatorPhase.isReady }
    var menuBarShowsGlobalKey: Bool { settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyDefault }

    var menuBarComputerUseAvailable: Bool { onboarding.computerUseSetup.phase == .ready }
    func menuBarComputerUseSession() async -> MenuBarMenuState.ComputerUse.Session? { await ComputerUseUserSessions.shared.menuBarSession() }
    func menuBarSetComputerUsePaused(_ id: String, _ paused: Bool) async throws { try await ComputerUseUserSessions.shared.setPaused(id, paused) }
    var menuBarUnread: [MenuBarMenuState.Chat] { AgentPriorityChats.app.menuBarChats(running: false) }
    var menuBarRunning: [MenuBarMenuState.Chat] { AgentPriorityChats.app.menuBarChats(running: true) }
    func menuBarChatImage(_ chat: MenuBarMenuState.Chat) -> NSImage? { AgentPriorityChats.menuBarImage(harness: chat.harness) }
    func menuBarOpenChat(_ id: String) { if let lane = AgentPriorityChats.app.lane(id) { SidebarPriorityFeed.open(lane, services: self) } }
}
