import CmuxMobileShellModel
import Foundation

/// A feed row prepared off the main actor: the immutable item plus every
/// derived string the row renders. Rows used to normalize, fold, and format
/// these inside `body`, which ran per row materialization during scroll; the
/// projection now builds one model per item on its background rebuild task.
struct NotificationFeedRowModel: Identifiable, Equatable, Sendable {
    let item: MobileNotificationFeedItem
    let presentation: NotificationFeedRowPresentation

    init(item: MobileNotificationFeedItem) {
        self.item = item
        presentation = NotificationFeedRowPresentation(item: item)
    }

    var id: MobileNotificationFeedItemID { item.id }
    var notificationID: String { item.notificationID }

    /// `presentation` is a pure derivation of `item`, so equality compares the
    /// item alone and list diffs stay as cheap as they were with raw-item
    /// sections.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }
}
