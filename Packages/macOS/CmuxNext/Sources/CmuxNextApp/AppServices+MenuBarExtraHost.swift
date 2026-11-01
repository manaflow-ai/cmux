import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextSettings

extension AppServices: MenuBarExtraHost {
    var menuBarAccount: MenuBarMenuState.Account? { SidebarAccount(cloud.auth)?.menuBarAccount }
    var menuBarAvatar: NSImage? { SidebarAccount(cloud.auth)?.avatar.image(diameter: 16) }
    var menuBarAgentsWorking: Int { workingAgentTabCount() }
    var menuBarAgentsNeedingInput: Int { AgentNeedsInputJump.targets(chats: .app, tabs: AgentNeedsInputJump.tabs(of: daemon.store)).count }
    var menuBarUpdateReady: Bool { updater.indicatorPhase.isReady }
    var menuBarShowsGlobalKey: Bool { settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyFallback }
}
