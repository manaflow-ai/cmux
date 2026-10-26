import AppKit
import CmuxNextAgentPane
import CmuxNextWakeups

// Launch work no first frame needs, posted to the launch's StartupScheduler with one service per
// post, so no main turn after the first frame runs two of them (Chrome's
// AfterStartupTaskUtils::PostTask, chrome/browser/after_startup_task_utils.cc: every deferred
// startup task is its own post, released one at a time once startup is complete).
extension AppServices {
    /// The free-tier attest, SSH, server reach and the updater (Sparkle): afterStartup, one post each.
    func postNonPaintServices(on startup: StartupScheduler) {
        startup.post(.afterStartup, "FreeTierAttest.start", on: .main) { [weak self] in self?.startFreeTierAttest() }
        startup.post(.afterStartup, "SSH.start", on: .main) { [weak self] in self?.ssh.start() }
        startup.post(.afterStartup, "ServerReach.start", on: .main) { [weak self] in self?.serverReach.start() }
        startup.post(.afterStartup, "Updater.start", on: .main) { [weak self] in
            guard let self else { return }
            updater.start()
            DebugTimings.markLaunch("launch.non_paint_services") // the last of the four posts
        }
    }

    /// Warm-ups for later tabs (WebKit for agent pages, Chromium, the New Tab spare, page hosts) and
    /// the agent tab import, one post each. Each reads current state when it runs, so nothing the
    /// window build did is missed.
    func postLaterTabWarmups(on startup: StartupScheduler) {
        postAgentPageWarmup(on: startup)
        // ChromiumWarmup only arms its own launch timers here; task 018 moves them onto the scheduler.
        startup.post(.afterFirstFrame, "ChromiumWarmup.start", on: .main) { [weak self] in
            guard let self, !crashRecovery.recovery.skipsBrowserPages else { return }
            startChromiumWarmup()
        }
        startup.post(.afterStartup, "NewTabSpares.start", on: .main) { [weak self] in self?.newTabSpares.start() }
        startup.post(.afterStartup, "PageHostPool.start", on: .main) { [weak self] in self?.startPageHostPool() }
        startup.post(.afterStartup, "AgentTabImport.start", on: .main) { [weak self] in
            guard let self else { return }
            AgentTabImport.start(self)
            DebugTimings.markLaunch("launch.post_window_warmups") // the last of the warm-up posts
        }
    }

    /// The first WKProcessPool and its web content process: one named main turn (WebKit has no
    /// off-main path, `AgentPaneView+Warmup`). It takes the first afterFirstFrame slot when a visible
    /// pane shows an agent chat that opens in WebKit, so that page loads warm; else it waits for
    /// afterStartup. The decision is read at the first frame, when the restored panes exist.
    private func postAgentPageWarmup(on startup: StartupScheduler) {
        startup.post(.afterFirstFrame, "AgentPane.webKitWarmupSlot", on: .main) { [weak self] in
            guard let self else { return }
            if showsAgentChat, AgentPaneView.newPagesShowInWebKit {
                Self.warmAgentPages()
            } else {
                startup.post(.afterStartup, "AgentPane.webKitWarmup", on: .main) { Self.warmAgentPages() }
            }
        }
    }

    private static func warmAgentPages() {
        AgentPaneView.startWarmup()
        DebugTimings.markLaunch("launch.agent_page_warmup")
    }

    /// A visible window's visible pane has an agent chat selected.
    private var showsAgentChat: Bool {
        windows.controllers.contains { controller in
            guard controller.window?.isVisible == true, let content = controller.content else { return false }
            return content.panes.values.contains { pane in
                guard pane.presence == .visible, let tab = pane.selectedTab else { return false }
                return tab.kind == .conversation && tab.agentSession != nil
            }
        }
    }

    private func startFreeTierAttest() {
        FreeTierAttestStarter(build: environment.build, bundle: .main, apiBaseURL: feed.apiBaseURL, settings: settings, signedIn: { [weak self] in self.map { $0.cloud.isSignedIn || $0.cloud.auth.isRestoring } ?? true }).start()
    }

    private func startPageHostPool() {
        pageHostPool.start(
            isMainWindow: { [weak self] window in
                self?.windows.controllers.contains { $0.window === window } == true
            },
            fallback: { [weak self] window in
                self?.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
            })
        pageHostPool.noteLikely()
    }
}
