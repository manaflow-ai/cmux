public import CmuxNextDaemon
import CmuxNextWakeups
import CmuxNextWindowRules

/// Agent-finished banners that land in one burst, per workspace (cx-kz6m0.1, parity with the old
/// app's coalescing queue; RFC #20891 proposal 3). The first finished turn in a workspace opens a
/// window; while it is open, each other unread agent that finishes there replaces every banner the
/// burst still shows with one digest that counts them ("3 agents finished", subtitled with the
/// workspace) and opens the newest. One agent finishing again is not a burst, and an agent the
/// user read leaves it. The digest is filed under the newest agent's tab: reading that tab
/// withdraws it, reading an older one leaves it. Approvals, questions and errors never come here,
/// and the daemon's notification history keeps every row. The window is a one-shot `DemandTimer`.
public final class FinishedBannerBursts {
    /// How long after a workspace's first finished turn others join its banner.
    public static let window: Duration = .seconds(10)

    /// A finished turn's banner becomes a digest of `count` agents, replacing the banners `replacing`.
    public struct Digest: Equatable, Sendable, Decodable {
        public var count: Int
        public var replacing: [String]
    }

    /// A workspace's open burst: its one-shot timer and what cmux-window-rules `desktop_bursts` keeps of it.
    private struct Open {
        let timer: DemandTimer
        var burst: Burst
    }

    private var bursts: [String: Open] = [:]
    /// Banner ids a digest replaced, newest last (bounded; for tests and `debug.notifications`).
    public private(set) var replaced: [String] = []

    public init() {}

    /// Whether `workspace` has a burst open.
    public func isOpen(workspace: String) -> Bool { bursts[workspace] != nil }

    /// Adds `notification`, on `tab` in `workspace`, to the burst when it is a finished turn without
    /// a reply field, opening one if none is open. A digest only while another unread agent's
    /// banner is still showing; nil: the banner posts on its own (and when the rule does not answer).
    public func join(_ notification: DaemonNotification, workspace: String, tab: String, clock: any Clock<Duration>) -> Digest? {
        let open = bursts[workspace]
        let ask = JoinAsk(burst: open?.burst, notification: notification.notification.rawValue,
                          finishedTurn: notification.isFinishedTurn, reply: notification.reply, tab: tab)
        guard let joined = WindowRules().call("window_notifications_desktop_burst_join", ask, as: Joined.self),
              let burst = joined.burst else { return nil }
        let timer = open?.timer ?? {
            let timer = DemandTimer(owner: "notifications.finishedBurst", clock: clock)
            timer.schedule(after: Self.window) { @MainActor [weak self] in self?.bursts[workspace] = nil }
            return timer
        }()
        bursts[workspace] = Open(timer: timer, burst: burst)
        guard let digest = joined.digest else { return nil }
        replaced = Array((replaced + digest.replacing).suffix(64))
        return digest
    }

    /// The user read `tab`: its agent leaves its burst, and a burst left empty closes.
    public func read(tab: String) {
        for (workspace, open) in bursts where open.burst.tabs.contains(tab) {
            guard let left = WindowRules().call("window_notifications_desktop_burst_read", ReadAsk(burst: open.burst, tab: tab),
                                                as: Left.self) else { continue }
            if left.closes {
                open.timer.cancel()
                bursts[workspace] = nil
            } else {
                bursts[workspace] = Open(timer: open.timer, burst: left.burst)
            }
        }
    }
}

extension DaemonNotification {
    /// An agent's turn completion (`agent.turn.completed`, "<Agent> finished"): the agent source's
    /// info level. Its asks (approval, question, plan review) are warnings and its errors errors.
    public nonisolated var isFinishedTurn: Bool { source == "agent" && level == .info }
}

extension TabModel {
    /// The tab's unread marker is another notification's warning or error, still to be seen.
    public func holdsUnreadAsk(besides other: DaemonNotification) -> Bool {
        guard let marker = notification, marker.unread, marker.notification != other.notification else { return false }
        return marker.level == .warning || marker.level == .error
    }
}
