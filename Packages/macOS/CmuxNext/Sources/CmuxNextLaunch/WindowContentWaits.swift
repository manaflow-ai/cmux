public import CmuxNextWakeups

/// The off-screen waits of windows none of whose workspaces a machine reports yet (audit B7): a window kept off screen
/// for its content waits at most its ``Reason/limit``, then shows with its wait state (the connecting view, "Reconnecting
/// to <machine>…" for a Cloud machine's window), never off screen with no limit. A new window waits two frames from the
/// press (Cmd-Shift-N whose create waits for the daemon: cmux Classic Mode's terminal, no local agent host); a restored
/// window 750 ms, so a Cloud machine that reconnects at launch still shows its content first, with no wait state between.
///
/// Each wait is one measured stage (`debug.windows`): why it waited, how long, and what ended it: its content, its
/// limit (then how long its content took after), or the window closing first.
///
/// ```swift
/// waits.begin(id, reason: .restored) { presentWithWaitState(id) } // false: not built yet, asked again next frame
/// waits.end(id, .content)                                         // its content showed first: cancelled, recorded
/// ```
@MainActor
public final class WindowContentWaits {
    /// Why a window waits off screen.
    public enum Reason: String, Sendable {
        /// A new window whose first workspace no machine reports yet (Cmd-Shift-N, a tear-off).
        case newWindow = "new_window"
        /// A restored or reopened window none of whose workspaces is mirrored (its machine offline or still connecting).
        case restored

        /// The longest the window waits off screen: two frames for a new window (the person sees the window in the
        /// frames after the press), 750 ms for a restored one (a machine that reconnects at launch beats it).
        public var limit: Duration { self == .newWindow ? .milliseconds(33) : .milliseconds(750) }
    }

    /// What ended a wait.
    public enum End: String, Sendable, CaseIterable {
        /// Its content showed within the limit.
        case content
        /// The limit passed: the window shows its wait state.
        case limit
        /// The window closed (or its create failed) first.
        case closed
    }

    /// One wait's measured stage.
    public struct Stage: Equatable, Sendable {
        public let reason: Reason
        /// How long the window stayed off screen.
        public let waitedMs: Double
        public let end: End
        /// After its limit: when its content showed, from the wait's start; nil until it does.
        public internal(set) var contentMs: Double?
    }

    private struct Wait {
        let reason: Reason
        let began: Duration
        let deadline: MainDeadline
        let show: @MainActor () -> Bool
        /// Frames the window was not built yet at its limit.
        var retries = 0
    }

    /// A window not built at its limit is asked again each frame, at most this often (its claim comes within a turn
    /// or two of the press; one that never comes leaves no window off screen, only no window).
    static let maxRetries = 30

    private let deadlines: MainDeadlineScheduler
    // memory: bounded by the windows waiting off screen now (each ends at its content, its limit or its close)
    private var waits: [String: Wait] = [:]
    // memory: bounded by the open windows shown at their limit whose content has not shown yet
    private var shownWaiting: [String: Duration] = [:]
    // memory: one small value per open window that waited (dropped when it closes)
    /// Each open window's last wait.
    public private(set) var stages: [String: Stage] = [:]
    /// How many waits each end ended since launch.
    public private(set) var ends: [End: Int] = [:]

    /// - Parameter deadlines: The app's deadline scheduler: each limit is a `visible` deadline on it.
    public init(deadlines: MainDeadlineScheduler) {
        self.deadlines = deadlines
    }

    /// True while window `id` waits off screen.
    public func isWaiting(_ id: String) -> Bool { waits[id] != nil }

    /// True while window `id` shows its wait state: shown at its limit, its content not shown yet. The one window on
    /// screen allowed without a mirrored workspace (`WindowInvariants`).
    public func showsWaitState(_ id: String) -> Bool { shownWaiting[id] != nil }

    /// Starts window `id`'s wait. At the limit `show` presents it with its wait state and returns true (also when there
    /// is nothing left to show), or false while the window is not built yet. A window that waits already keeps its
    /// start, its limit and its `show`: a new window's wait runs from the press.
    public func begin(_ id: String, reason: Reason, show: @escaping @MainActor () -> Bool) {
        guard waits[id] == nil, shownWaiting[id] == nil else { return }
        let deadline = MainDeadline(owner: "window.contentWait", workClass: .visible,
                                    alignment: reason == .newWindow ? .precise : .flexible, scheduler: deadlines)
        waits[id] = Wait(reason: reason, began: deadlines.uptime, deadline: deadline, show: show)
        deadline.schedule(after: reason.limit) { [weak self] in self?.limitPassed(id) }
    }

    /// Ends window `id`'s wait (nothing when it has none): `content` when it installed workspace content, `closed`
    /// when it closed. Cheap: every workspace switch reports its content.
    public func end(_ id: String, _ end: End) {
        if let wait = waits.removeValue(forKey: id) {
            wait.deadline.cancel()
            ends[end, default: 0] += 1
            stages[id] = end == .closed ? nil : Stage(reason: wait.reason, waitedMs: since(wait.began), end: end)
            return
        }
        let shownSince = shownWaiting.removeValue(forKey: id)
        if end == .closed {
            stages[id] = nil
        } else if let shownSince, end == .content {
            stages[id]?.contentMs = since(shownSince)
        }
    }

    private func limitPassed(_ id: String) {
        guard var wait = waits[id] else { return }
        guard wait.show() else {
            wait.retries += 1
            if wait.retries >= Self.maxRetries { return } // no window to show; its content or its close ends the wait
            waits[id] = wait
            return wait.deadline.schedule(after: .milliseconds(16)) { [weak self] in self?.limitPassed(id) }
        }
        // `show` may have ended the wait itself (its content showed, it closed).
        guard waits.removeValue(forKey: id) != nil else { return }
        ends[.limit, default: 0] += 1
        stages[id] = Stage(reason: wait.reason, waitedMs: since(wait.began), end: .limit)
        shownWaiting[id] = wait.began
    }

    private func since(_ began: Duration) -> Double {
        let elapsed = (deadlines.uptime - began).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
