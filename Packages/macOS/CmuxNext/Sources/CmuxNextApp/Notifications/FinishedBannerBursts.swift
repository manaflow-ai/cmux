import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Agent-finished banners that land in one burst, per workspace (cx-kz6m0.1, parity with the old
/// app's coalescing queue; RFC #20891 proposal 3). The first finished turn in a workspace opens a
/// window; while it is open, each other unread agent that finishes there replaces every banner the
/// burst still shows with one that counts them ("3 agents finished", subtitled with the workspace)
/// and opens the newest. One agent finishing again is not a burst, and an agent the user read
/// leaves it. The digest is filed under the newest agent's tab: reading that tab withdraws it,
/// reading an older one leaves it. Approvals, questions and errors never come here, and the
/// daemon's notification history keeps every row. The window is a one-shot `DemandTimer`.
@MainActor
final class FinishedBannerBursts {
    /// How long after a workspace's first finished turn others join its banner.
    static let window: Duration = .seconds(10)

    struct Burst {
        let timer: DemandTimer
        /// Unread tabs whose agents finished in this burst.
        var tabs: Set<String> = []
        /// The burst's banners still showing, with the tab each is filed under.
        var showing: [(id: String, tab: String)] = []
    }

    /// What a finished turn does: post on its own, or replace `replacing` with a digest of `count`.
    enum Outcome {
        case own
        case digest(count: Int, replacing: [(id: String, tab: String)])
    }

    private var bursts: [String: Burst] = [:]

    /// Adds a finished turn on `tabID` in `workspace` (its banner `bannerID`) to the burst, opening
    /// one if none is open. A digest only when another unread agent's banner is still showing.
    func join(workspace: String, tabID: String, bannerID: String, clock: any Clock<Duration>,
              ended: @escaping @MainActor @Sendable (String) -> Void) -> Outcome {
        var burst = bursts[workspace] ?? {
            let timer = DemandTimer(owner: "notifications.finishedBurst", clock: clock)
            timer.schedule(after: Self.window) { @MainActor [weak self] in
                self?.bursts[workspace] = nil
                ended(workspace)
            }
            return Burst(timer: timer)
        }()
        burst.tabs.insert(tabID)
        let previous = burst.showing
        let others = previous.contains { $0.tab != tabID }
        burst.showing = others ? [(bannerID, tabID)] : previous + [(bannerID, tabID)]
        bursts[workspace] = burst
        return others && burst.tabs.count > 1 ? .digest(count: burst.tabs.count, replacing: previous) : .own
    }

    /// The user read `tabID`: its agent leaves its burst, and a burst left empty closes.
    func read(tab tabID: String) {
        for (workspace, var burst) in bursts where burst.tabs.contains(tabID) {
            burst.tabs.remove(tabID)
            burst.showing.removeAll { $0.tab == tabID }
            if burst.tabs.isEmpty {
                burst.timer.cancel()
                bursts[workspace] = nil
            } else {
                bursts[workspace] = burst
            }
        }
    }

    /// The burst banner's title: "3 agents finished" (its subtitle names the workspace).
    static func title(count: Int) -> String {
        String(localized: "notifications.finishedBurst.title", defaultValue: "\(count) agents finished",
               table: "NotificationsPanel", bundle: .module)
    }
}

extension NotificationCenterService {
    /// Posts a finished turn's banner, joining it to its workspace's burst. False when
    /// `notification` is not a finished turn that can share a banner (it posts as usual).
    func postFinishedTurn(_ notification: DaemonNotification, located: LocatedTab, program: ProgramStatusNotification?) -> Bool {
        guard Self.isFinishedTurn(notification), program == nil, !(notification.reply && located.tab.kind == .pty) else { return false }
        let id = Self.bannerID(notification)
        let workspace = located.workspace.id
        let outcome = finishedBursts.join(workspace: workspace, tabID: located.tab.id, bannerID: id, clock: clock,
                                          ended: { [weak self] in self?.note("finished burst ended \($0)") })
        guard case let .digest(count, replacing) = outcome else { return false }
        for banner in replacing { banners[banner.tab]?.removeAll { $0 == banner.id } }
        desktop.withdraw(replacing.map { $0.id })
        let title = FinishedBannerBursts.title(count: count)
        let latest = notification.title.isEmpty ? located.tab.displayTitle : notification.title
        // A banner it replaces already sounded: the digest is silent.
        desktop.post(id: id, title: title, subtitle: located.workspace.displayName, body: latest,
                     surface: notification.surface?.rawValue, workspace: workspace, defaultSound: false)
        banners[located.tab.id, default: []].append(id)
        note("finished burst \(count) in \(workspace)")
        return true
    }
}
