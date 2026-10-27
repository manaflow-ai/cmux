public import CmuxNextDaemon
import CmuxNextWakeups

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
    public struct Digest: Equatable, Sendable {
        public var count: Int
        public var replacing: [String]
    }

    private struct Burst {
        let timer: DemandTimer
        /// Unread tabs whose agents finished in this burst.
        var tabs: Set<String> = []
        /// The burst's banners still showing, with the tab each is filed under.
        var showing: [(id: String, tab: String)] = []
    }

    private var bursts: [String: Burst] = [:]
    /// Banner ids a digest replaced, newest last (bounded; for tests and `debug.notifications`).
    public private(set) var replaced: [String] = []

    public init() {}

    /// Whether `workspace` has a burst open.
    public func isOpen(workspace: String) -> Bool { bursts[workspace] != nil }

    /// Adds `notification`, on `tab` in `workspace`, to the burst when it is a finished turn without
    /// a reply field, opening one if none is open. A digest only while another unread agent's
    /// banner is still showing; nil: the banner posts on its own.
    public func join(_ notification: DaemonNotification, workspace: String, tab: String, clock: any Clock<Duration>) -> Digest? {
        guard notification.isFinishedTurn, !notification.reply else { return nil }
        let banner = "cmux-notification-\(notification.notification.rawValue)"
        var burst = bursts[workspace] ?? {
            let timer = DemandTimer(owner: "notifications.finishedBurst", clock: clock)
            timer.scheduleOnMain(after: Self.window) { [weak self] in self?.bursts[workspace] = nil }
            return Burst(timer: timer)
        }()
        burst.tabs.insert(tab)
        let previous = burst.showing
        let others = previous.contains { $0.tab != tab }
        burst.showing = others ? [(banner, tab)] : previous + [(banner, tab)]
        bursts[workspace] = burst
        guard others else { return nil }
        replaced = Array((replaced + previous.map { $0.id }).suffix(64))
        return Digest(count: burst.tabs.count, replacing: previous.map { $0.id })
    }

    /// The user read `tab`: its agent leaves its burst, and a burst left empty closes.
    public func read(tab: String) {
        for (workspace, var burst) in bursts where burst.tabs.contains(tab) {
            burst.tabs.remove(tab)
            burst.showing.removeAll { $0.tab == tab }
            if burst.tabs.isEmpty {
                burst.timer.cancel()
                bursts[workspace] = nil
            } else {
                bursts[workspace] = burst
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
