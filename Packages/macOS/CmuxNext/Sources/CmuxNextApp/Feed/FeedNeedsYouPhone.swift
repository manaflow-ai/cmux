import CmuxNextCompat
import CmuxNextFeed
import CmuxNextMobile
import CmuxNextMobileHost
import Foundation

/// The Feed's pinned open requests reach the iPhone (manaflow-ai/cmux#33818): PRs held for
/// trial, sign-ins and consent cards live only in this app's Feed, which the phone never reads.
/// Each time the pinned set changes the whole set goes to `cmux-mobile-host`, which serves it
/// to the phone's Feed and pushes each request once (`needs_you.rs` keeps every rule; this only
/// forwards). Agent approvals are left out: the phone has those from acpmux already.
///
/// Stop condition: the task ends when `NotificationCenterService.stop` cancels its tasks.
@MainActor
enum FeedNeedsYouPhone {
    /// The open requests the Feed pins, as the phone gets them.
    static func requests(_ pinned: [FeedItem], detail: (FeedItem) -> GitHubFeedDetail?) -> [MobileHostNeedsYouRequest] {
        pinned.compactMap { item in
            // An agent's approval reaches the phone from acpmux (its own pinned ask).
            guard item.isOpenRequest, item.context.acpSession == nil else { return nil }
            let github = detail(item)
            return MobileHostNeedsYouRequest(
                id: item.id, title: github?.title ?? item.title, body: item.body, kind: item.kind,
                source: item.poster.label, url: item.context.url ?? github?.url, createdAt: item.createdAt)
        }
    }

    /// What the phone gets from `model` now, or nil while its owner has not answered: an empty
    /// set sent before the Feed loads, or while it is unreachable, would close every request on
    /// the phone and clear its delivered push.
    static func current(_ model: FeedModel, detail: (FeedItem) -> GitHubFeedDetail?) -> [MobileHostNeedsYouRequest]? {
        guard model.loaded, model.connection == .connected else { return nil }
        return requests(model.listSections.requests, detail: detail)
    }

    /// Follows the Feed's pinned requests and hands each new set to the iPhone host.
    static func follow(feed: FeedService, iphone: IPhoneHostService) -> Task<Void, Never> {
        // task-owner: NotificationCenterService.tasks; cancelled with the service.
        Task { [weak feed, weak iphone] in
            let pinned = ObservationStream { [weak feed] () -> [MobileHostNeedsYouRequest]? in
                guard let feed else { return nil }
                return current(feed.model) { feed.githubDetail(for: $0) }
            }
            for await set in pinned {
                guard let set else { continue }
                await iphone?.setNeedsYou(set)
            }
        }
    }
}
