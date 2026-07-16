import CmuxMobileShellModel
import Foundation
import Observation

/// A stable day bucket prepared outside the list body.
struct NotificationFeedDaySection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case today
        case yesterday
        case dated
    }

    let id: Date
    let kind: Kind
    let items: [MobileNotificationFeedItem]
}

/// Prepares the user-selected, reverse-chronological day sections consumed by
/// the feed list. Filtering, sorting, and grouping run only when their inputs
/// change, never during a row or list body evaluation.
@MainActor
@Observable
final class NotificationFeedProjection {
    var filter: MobileNotificationFeedFilter = .all {
        didSet { rebuild() }
    }

    private(set) var sections: [NotificationFeedDaySection] = []
    private(set) var sourceItemCount = 0
    private(set) var sourceUnreadCount = 0

    @ObservationIgnored private var sourceItems: [MobileNotificationFeedItem] = []
    @ObservationIgnored private var referenceDate: Date
    @ObservationIgnored private var calendar: Calendar

    init(referenceDate: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    func update(
        items: [MobileNotificationFeedItem],
        referenceDate: Date = .now
    ) {
        guard sourceItems != items || self.referenceDate != referenceDate else { return }
        sourceItems = items
        self.referenceDate = referenceDate
        sourceItemCount = items.count
        sourceUnreadCount = items.lazy.filter { !$0.isRead }.count
        rebuild()
    }

    private func rebuild() {
        let visibleItems = filter.apply(to: sourceItems).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        let grouped = Dictionary(grouping: visibleItems) { item in
            calendar.startOfDay(for: item.createdAt)
        }
        let today = calendar.startOfDay(for: referenceDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)

        sections = grouped.keys.sorted(by: >).map { day in
            let kind: NotificationFeedDaySection.Kind
            if calendar.isDate(day, inSameDayAs: today) {
                kind = .today
            } else if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) {
                kind = .yesterday
            } else {
                kind = .dated
            }
            return NotificationFeedDaySection(
                id: day,
                kind: kind,
                items: grouped[day] ?? []
            )
        }
    }
}
