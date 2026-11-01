import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextSettings

extension AppServices: MenuBarExtraHost {
    var menuBarAccount: MenuBarMenuState.Account? { SidebarAccount(cloud.auth)?.menuBarAccount }
    var menuBarAvatar: NSImage? { SidebarAccount(cloud.auth)?.avatar.image(diameter: 16) }
    var menuBarAgentsWorking: Int { workingAgentTabCount() }
    var menuBarAgentsNeedingInput: Int { AgentPriorityChats.app.needingInput().count }
    var menuBarUpdateReady: Bool { updater.indicatorPhase.isReady }
    var menuBarShowsGlobalKey: Bool { settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyFallback }
}
