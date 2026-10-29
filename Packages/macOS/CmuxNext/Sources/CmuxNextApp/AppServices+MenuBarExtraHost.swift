import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextSettings

extension AppServices: MenuBarExtraHost {
    var menuBarAccount: MenuBarMenuState.Account? { SidebarAccount(cloud.auth)?.menuBarAccount }
    var menuBarAvatar: NSImage? { SidebarAccount(cloud.auth)?.avatar.image(diameter: 16) }
    var menuBarAgentsWorking: Int { workingAgentTabCount() }
    var menuBarAgentsNeedingInput: Int { Set(daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter(StatusMapping.shared.needsInput).map(\.id)).count }
    var menuBarUpdateReady: Bool { updater.indicatorPhase.isReady }
    var menuBarShowsGlobalKey: Bool { settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyFallback }
}
