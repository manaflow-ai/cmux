import AppKit
import CmuxNextWakeups
import Foundation
import os

nonisolated private let retryLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")

/// How many times an agent page whose web content process ended loads again by itself before the
/// crash notice shows (Leo, 2026-11-01, on "The agent pane crashed. [Reload]": "how come it says
/// this??? why doens't it just retry on its own").
///
/// Each end within ``window`` of the first retries, after the ``backoff`` of its turn, up to
/// ``limit`` retries; the next end in the window shows the notice. A page that loads and ends
/// again counts too: that is the crash loop the notice is for.
nonisolated struct AgentPageCrashBudget: Equatable, Sendable {
    static let limit = 3
    static let window: TimeInterval = 60
    /// The wait before the first, second and third retry in a window.
    static let backoff: [TimeInterval] = [0, 1, 4]

    enum Step: Equatable, Sendable {
        /// Load the page again in a new process after `delay` seconds.
        case retry(delay: TimeInterval)
        /// It kept ending: the crash notice, with Reload.
        case notice
    }

    private var retries: [Date] = []

    /// The page ended at `now`: what follows.
    mutating func ended(at now: Date) -> Step {
        retries.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard retries.count < Self.limit else { return .notice }
        let delay = Self.backoff[min(retries.count, Self.backoff.count - 1)]
        retries.append(now)
        return .retry(delay: delay)
    }

    /// The person pressed Reload: the next end retries again.
    mutating func reset() { retries.removeAll() }
}

/// An agent pane's automatic retries after its page's process ended (``AgentPageCrashBudget``):
/// a pane on screen retries once its backoff passed, a pane nobody sees when it is next shown, so
/// the background chats of an ended group do not all start a process at once.
@MainActor
final class AgentPageCrashRetry {
    var budget = AgentPageCrashBudget()
    /// A retry waits: for its backoff (``waiting``) or for the pane to be shown.
    private(set) var owed = false
    /// The backoff of the owed retry has not passed yet.
    private(set) var waiting = false
    /// Retries made (tests, `debug.agent_pane`).
    private(set) var count = 0
    private var serial = 0
    private var probe: AgentPaneVisibilityProbe?
    var now: () -> Date = Date.init
    private let backoff = DemandTimer(owner: "agent-page.crash-retry")
    /// Runs `body` after `delay` seconds (tests run it themselves).
    lazy var after: (_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Void = { [backoff] delay, body in
        backoff.schedule(after: .seconds(delay)) { @MainActor in body() }
    }
    /// Whether nobody can see the pane (tests set it).
    var nobodySees: @MainActor (NSView) -> Bool = AgentPaneFramePacer.nobodySees

    /// `view`'s page ended: true when it retries (``AgentPaneView/retryAfterCrash()``), false when
    /// it kept ending and shows the crash notice.
    func ended(_ view: AgentPaneView) -> Bool {
        guard case .retry(let delay) = budget.ended(at: now()) else {
            cancel()
            return false
        }
        owed = true
        waiting = true
        serial += 1
        let serial = serial
        watch(view)
        after(delay) { [weak self, weak view] in
            guard let self, let view, self.serial == serial else { return }
            self.waiting = false
            self.runIfShown(view)
        }
        return true
    }

    /// The person pressed Reload, or the page loaded again or closed: no owed retry runs.
    func cancel() {
        owed = false
        waiting = false
        serial += 1
        backoff.cancel()
    }

    /// Runs the owed retry if its backoff passed and somebody can see `view`.
    func runIfShown(_ view: AgentPaneView) {
        guard owed, !waiting else { return }
        guard !nobodySees(view) else {
            retryLogger.error("agent page retries when shown session=\(view.model.sessionId ?? "none", privacy: .public)")
            return
        }
        owed = false
        count += 1
        retryLogger.error("agent page loads again after its web content ended session=\(view.model.sessionId ?? "none", privacy: .public) retry=\(self.count)")
        view.retryAfterCrash()
    }

    private func watch(_ view: AgentPaneView) {
        guard probe == nil else { return }
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        probe.onChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.runIfShown(view)
        }
        view.addSubview(probe)
        self.probe = probe
    }
}
