import CmuxMobileShellModel
import Foundation

/// The last authoritative notification list received from one Mac.
struct NotificationFeedMacSnapshot {
    var revision: Int
    var items: [MobileNotificationFeedItem]
}
