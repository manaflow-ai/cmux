import CmuxNextMobile
import CmuxNextMobileHost
import Foundation
import CmuxNextFeedClient

/// The Feed's pinned open requests reach the iPhone (manaflow-ai/cmux#33818): PRs held for
/// trial, sign-ins and consent cards live only in this app's Feed, which the phone never reads.
/// Each time the feed changes, the daemon's Needs you view (`feed.view.read {layout: needs_you}`)
/// goes whole to `cmux-mobile-host`, which serves it to the phone's Feed and pushes each request
/// once (`needs_you.rs` keeps every rule; this only forwards). Agent approvals are left out: the
/// phone has those from acpmux already.
///
/// Stop condition: the task ends when `NotificationCenterService.stop` cancels its tasks.
@MainActor
enum FeedNeedsYouPhone {
    /// The open requests the Feed pins, as the phone gets them.
    static func requests(_ pinned: [FeedDaemonItem]) -> [MobileHostNeedsYouRequest] {
        pinned.compactMap { item in
            // An agent's approval reaches the phone from acpmux (its own pinned ask).
            guard item.isOpenRequest, item.context?.acpSession == nil else { return nil }
            return MobileHostNeedsYouRequest(
                id: item.id, title: item.github?.title ?? item.title ?? "", body: item.body ?? "", kind: item.kind ?? "",
                source: item.poster?.label ?? "", url: item.url, createdAt: item.createdDate)
        }
    }

    /// What the phone gets from `view`, or nil while its owner has not answered: an empty set sent
    /// before the Feed loads, or while it is unreachable, would close every request on the phone and
    /// clear its delivered push.
    static func current(_ view: FeedDaemonView) -> [MobileHostNeedsYouRequest]? {
        guard view.isLive else { return nil }
        return requests(view.items(in: "needs_you"))
    }

    /// Follows the daemon's Needs you view and hands each new set to the iPhone host.
    static func follow(feed: FeedService, iphone: IPhoneHostService) -> Task<Void, Never> {
        let daemon = feed.daemon
        // task-owner: NotificationCenterService.tasks; cancelled with the service.
        return Task { [weak iphone] in
            var last: [MobileHostNeedsYouRequest]?
            for await _ in daemon.changes() {
                guard let view = try? await daemon.view(.needsYou), let set = current(view), set != last else { continue }
                last = set
                await iphone?.setNeedsYou(set)
            }
        }
    }
}
