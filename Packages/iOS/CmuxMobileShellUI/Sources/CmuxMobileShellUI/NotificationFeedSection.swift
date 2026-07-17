import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One immutable calendar-day section rendered by the notification feed.
struct NotificationFeedSection: Identifiable {
    let day: NotificationFeedDay
    let items: [MobileNotificationFeedItem]

    var id: String {
        switch day {
        case .today: "today"
        case .yesterday: "yesterday"
        case .older(let date): "older-\(date.timeIntervalSince1970)"
        }
    }
}
