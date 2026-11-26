import CmuxMobileShellModel

struct NotificationFeedProjectionOutput: Sendable {
    let sections: [NotificationFeedDaySection]
    let hasMoreRows: Bool
}
