import CmuxNextWakeups
import os

/// Restarts a hung agent-chat renderer by itself (#45888).
///
/// Every agent chat is the same first-party page, and the fork keeps one Chromium renderer per site
/// for cmux's page scheme (`CEFSwitches.processPerSitePageSchemes`): all open chats share one
/// renderer. When that renderer stops answering, every chat stops taking clicks and keys, and each
/// chat opened after it joins the same hung process, never reaches the host and falls back to WebKit
/// after its 8 s deadline. Until now only a person's "Restart renderer" in App Health ended it, so
/// the chats stayed dead until the app quit (nightly, 2026-11-17: 38 chats fell back in 8 minutes,
/// and clicks into chats did nothing until the renderer was killed).
///
/// Chromium reports a hang only after its own hang timer ran out (about 15 s with no answer to an
/// input event). This waits ``limit`` more in that state, then ends the renderer through
/// ``PageWebView/restartRenderer()``: each page in it reloads in a new renderer (the chat itself as
/// a repair, the others through their crash reload), which the shared App Health action does too.
/// A renderer that answers again before the limit cancels the restart.
@MainActor
final class AgentRendererHangRestart {
    /// Extra time a renderer Chromium already reports hung gets before it is ended.
    static let limit: Duration = .seconds(5)

    private let timer: DemandTimer
    private let limit: Duration
    /// Whether the restart may run now (the page still shows in this session, no page holds edits).
    private let mayRestart: @MainActor () -> Bool
    private let restart: @MainActor () -> Void
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")
    /// Restarts made (tests, `debug.page`).
    private(set) var restarts = 0

    init(clock: any Clock<Duration>, limit: Duration = AgentRendererHangRestart.limit,
         mayRestart: @escaping @MainActor () -> Bool, restart: @escaping @MainActor () -> Void) {
        timer = DemandTimer(owner: "page.chromium.agentHangRestart", clock: clock)
        self.limit = limit
        self.mayRestart = mayRestart
        self.restart = restart
    }

    /// Whether a restart waits for the limit now.
    var isPending: Bool { timer.isScheduled }

    /// The renderer's hang state changed (Chromium's hang monitor, followed by the session).
    func rendererChanged(unresponsive: Bool) {
        guard unresponsive else { return timer.cancel() }
        guard !timer.isScheduled else { return }
        // wakeup-allow: one bound on a renderer Chromium reports hung; cancelled when it answers again.
        timer.schedule(after: limit) { @MainActor [weak self] in self?.limitReached() }
    }

    /// The session ended (the page closed or fell back): nothing restarts.
    func cancel() { timer.cancel() }

    private func limitReached() {
        guard mayRestart() else { return }
        restarts += 1
        Self.logger.error("agent chat renderer unresponsive for \(self.limit, privacy: .public) after Chromium's hang report; restarting it")
        restart()
    }
}
