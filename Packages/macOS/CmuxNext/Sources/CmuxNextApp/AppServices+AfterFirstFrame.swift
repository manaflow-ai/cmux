import AppKit
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
        DebugTimings.markLaunch("launch.non_paint_services")
    }

    /// WebKit's process-wide start for agent pages (the shared process pool and data store, the
    /// first web view), in a frame of its own before any deferred chat makes its view.
    func startWebKitWarmup() {
        AgentPaneView.startWarmup()
        DebugTimings.markLaunch("launch.agent_page_warmup")
    }

    /// Warm-ups for later tabs (Chromium, the New Tab spare, page hosts) and the agent tab import.
    /// Each reads current state when it starts, so nothing the window build did is missed.
    func startLaterTabWarmups() {
        if !crashRecovery.recovery.skipsBrowserPages { startChromiumWarmup() }
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
