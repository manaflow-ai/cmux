#if os(iOS)
import CmuxMobileFeed
import CmuxMobileNotifications
import UserNotifications

/// Notification Center follows the Feed's Needs you asks.
///
/// The Mac pushes each new question and permission request once (cmux-mobile-host's
/// `Classifier` never reports an event id twice, across re-watches and reconnects). That push
/// stays in Notification Center after the ask closes on the Mac or another device; once the
/// Feed knows it closed (`FeedStore.isClosedAsk`), its notification leaves. The count of open
/// asks is the Feed tab's badge (`FeedStore.needsYouCount`); the app icon gets none, since the
/// HIG notes a badge set to zero removes the app's notifications from Notification Center
/// (finished turns included) and a badge should count unread notifications only.
///
/// `ShellTabs` runs `sync` only when the set of open asks changes (`FeedStore.needsYouIDs`) or
/// the Feed finishes reading its Macs, so a re-render or a re-read of the same asks does
/// nothing. It runs while the app runs; there is no timer or observer to stop.
@MainActor
enum NeedsYouNotices {
    /// What `ShellTabs` keys the sync on.
    struct Key: Hashable {
        var open: Set<String>
        var live: Bool
    }

    static func key(_ store: FeedStore) -> Key {
        Key(open: store.needsYouIDs, live: store.syncState == .live)
    }

    /// The identifiers of delivered ask notifications whose asks the Feed knows closed.
    static func closed(_ delivered: [(identifier: String, payload: PushPayload)], in store: FeedStore) -> [String] {
        delivered.compactMap { notification in
            let payload = notification.payload
            guard payload.kind.isAsk else { return nil }
            // A request of the Mac app's own Feed (a PR held for trial, #33818): `feed-<id>`.
            if let event = payload.eventId, store.isClosedMacRequest(eventID: event, mac: payload.mac) {
                return notification.identifier
            }
            guard let permission = payload.permissionId,
                  store.isClosedAsk(permissionID: permission, mac: payload.mac) else { return nil }
            return notification.identifier
        }
    }

    /// Removes the closed asks' notifications. Nothing while the Feed is still reading its Macs:
    /// an ask it has not reloaded yet is not closed.
    static func sync(_ store: FeedStore) async {
        guard store.syncState == .live else { return }
        let center = UNUserNotificationCenter.current()
        let delivered: [(identifier: String, payload: PushPayload)] = await center.deliveredNotifications().compactMap { notification in
            let identifier = notification.request.identifier
            return PushPayload(userInfo: notification.request.content.userInfo).map { (identifier: identifier, payload: $0) }
        }
        let stale = closed(delivered, in: store)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }
}
#endif
