import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Agent-finished banners that land in one burst, per workspace (cx-kz6m0.1, parity with the old
/// app's coalescing queue; RFC #20891 proposal 3). The first finished turn in a workspace opens a
/// window; while it is open, each other agent that finishes there replaces the delivered banner
/// with one that counts them ("3 agents finished", subtitled with the workspace) and opens the
/// newest. One agent finishing again is not a burst. Approvals, questions and errors never come here, and the
/// daemon's notification history keeps every row. The window is a one-shot `DemandTimer`.
@MainActor
final class FinishedBannerBursts {
    /// How long after a workspace's first finished turn others join its banner.
    static let window: Duration = .seconds(10)

    struct Burst {
        let timer: DemandTimer
        /// Tabs whose agents finished in this burst.
        var tabs: Set<String> = []
        /// The banner showing for the burst and the tab it opens.
        var banner: (id: String, tab: String)?
    }

    private var bursts: [String: Burst] = [:]

    /// The banner for a finished turn on `tabID` in `workspace` (`bannerID` is its notification's
    /// banner id). Returns nil when it is not part of a burst and posts as usual; else the count of
    /// agents that finished, and the banner it replaces with that banner's tab.
    func join(workspace: String, tabID: String, bannerID: String, clock: any Clock<Duration>,
              ended: @escaping @MainActor @Sendable (String) -> Void) -> (count: Int, replacing: String?, replacingTab: String?)? {
        var burst = bursts[workspace] ?? {
            let timer = DemandTimer(owner: "notifications.finishedBurst", clock: clock)
            timer.schedule(after: Self.window) { @MainActor [weak self] in
                self?.bursts[workspace] = nil
                ended(workspace)
            }
            return Burst(timer: timer)
        }()
        burst.tabs.insert(tabID)
        let previous = burst.banner
        burst.banner = (bannerID, tabID)
        bursts[workspace] = burst
        guard burst.tabs.count > 1 else { return nil }
        return (burst.tabs.count, previous?.id, previous?.tab)
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
        guard let joined = finishedBursts.join(workspace: workspace, tabID: located.tab.id, bannerID: id, clock: clock,
                                               ended: { [weak self] in self?.note("finished burst ended \($0)") }) else {
            return false
        }
        if let replaced = joined.replacing {
            if let tab = joined.replacingTab { banners[tab]?.removeAll { $0 == replaced } }
            desktop.withdraw([replaced])
        }
        let title = FinishedBannerBursts.title(count: joined.count)
        let latest = notification.title.isEmpty ? located.tab.displayTitle : notification.title
        // The banner it replaces already sounded: the update is silent.
        desktop.post(id: id, title: title, subtitle: located.workspace.displayName, body: latest,
                     surface: notification.surface?.rawValue, workspace: workspace, defaultSound: false)
        banners[located.tab.id, default: []].append(id)
        note("finished burst \(joined.count) in \(workspace)")
        return true
    }
}
