import AppKit
import CmuxNextActions
import CmuxNextCrashReporting
import CmuxNextAgentPane

// Launch work no first frame needs: AppDelegate starts it once the first window's
// frame is committed (FirstFrameGate), so it never delays that frame (perf-launch-memory).
extension AppServices {
    /// The free-tier attest, SSH, server reach and the updater (Sparkle).
    func startNonPaintServices() {
        FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: feed.apiBaseURL, settings: settings, signedIn: { [weak self] in self.map { $0.cloud.isSignedIn || $0.cloud.auth.isRestoring } ?? true }).start()
        ssh.start()
        serverReach.start()
        updater.start()
        // The run's crash breadcrumbs: counts and kinds only, never a title, URL, path or terminal text.
        crashRecovery.recordContext(on: actionBudget.samples(everyRun: true)) { [weak self] in
            guard let self else { return CrashContext(updated: Date(), windows: 0, workspaces: 0, tabKinds: [], focusedPane: nil, browserEngine: nil, browserFailures: 0, footprintMegabytes: 0, actions: []) }
            let workspaces = daemon.store.workspaces
            let runs = actionBudget.recent(CrashContext.actionLimit).map { (id: $0.id.rawValue, entrypoint: $0.entrypoint.rawValue, startUptimeNanos: $0.startUptimeNanos) }
            return CrashContext(updated: Date(), windows: windows.controllers.count, workspaces: workspaces.count,
                                tabKinds: workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.kind.rawValue),
                                focusedPane: windows.active?.focusedPane?.selectedTab?.kind.rawValue, browserEngine: cache.cef.startReport.state,
                                browserFailures: cache.cef.crashLog.total, footprintMegabytes: CrashContext.footprintMegabytes(),
                                actions: CrashContext.actions(runs, now: Date(), nowUptimeNanos: ActionBudgetMonitor.now()))
        }
        DebugTimings.markLaunch("launch.non_paint_services")
    }

    /// Warm-ups for later tabs (WebKit for agent pages, Chromium, the New Tab spare, page hosts)
    /// and the agent tab import. Each reads current state when it starts, so nothing the window build did is missed.
    func startLaterTabWarmups() {
        AgentPaneView.startWarmup()
        DebugTimings.markLaunch("launch.agent_page_warmup")
        if !crashRecovery.recovery.isSafeRestart { startChromiumWarmup() }
        newTabSpares.start()
        pageHostPool.start(
            isMainWindow: { [weak self] window in
                self?.windows.controllers.contains { $0.window === window } == true
            },
            fallback: { [weak self] window in
                self?.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
            })
        pageHostPool.noteLikely()
        AgentTabImport.start(self)
        DebugTimings.markLaunch("launch.post_window_warmups")
    }
}
