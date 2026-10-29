import CmuxNextAgentPane
import CmuxNextLaunch
import CmuxNextPages

// The later-tab warm-ups' engines (LaterTabWarmups); `startChromiumWarmup` is the launch's own
// (AppServices+Chromium).
extension AppServices: LaterTabWarmupHost {
    var skipsBrowserPagesAtLaunch: Bool { crashRecovery.recovery.isSafeRestart }
    func armNewTabPreload() { newTabSpares.start(holdingWarm: true) }
    func warmAgentPages() -> String? { agentPageWarmup.start(webUI: webUI).launchMark }
    func probeNewTabPreload() { newTabSpares.prewarm() }
    func warmNewTabPreload() { newTabSpares.startWarming() }
    func startPagePreloads() { pagePreloads.start() }
    func startAgentTabImport() { AgentTabImport.start(self) }
    func buildRightSidebarIcons() { rightSidebarSections.buildIcons(.afterStartup) }
    func markLaunch(_ name: String) { DebugTimings.markLaunch(name) }
}
