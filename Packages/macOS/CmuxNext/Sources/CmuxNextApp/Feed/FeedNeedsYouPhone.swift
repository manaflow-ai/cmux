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
        _ = pinned  // red: not written yet
        return []
    }

    /// Follows the Feed's pinned requests and hands each new set to the iPhone host.
    static func follow(feed: FeedService, iphone: IPhoneHostService) -> Task<Void, Never> {
        // task-owner: NotificationCenterService.tasks; cancelled with the service.
        Task { [weak feed, weak iphone] in
            let pinned = ObservationStream { [weak feed] in
                feed.map { feed in requests(feed.model.listSections.requests) { feed.githubDetail(for: $0) } } ?? []
            }
            for await set in pinned {
                await iphone?.setNeedsYou(set)
            }
        }
    }
}
