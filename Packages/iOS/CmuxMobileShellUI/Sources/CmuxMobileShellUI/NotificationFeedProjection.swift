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
/// the feed list. The source feed is already sorted newest-first by
/// `MobileNotificationFeedAggregation`; this projection preserves that order
/// while filtering and grouping outside row or list body evaluation.
@MainActor
@Observable
final class NotificationFeedProjection {
    var filter: MobileNotificationFeedFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            scheduleRebuild()
        }
    }
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleRebuild(
                debounce: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .milliseconds(200)
            )
        }
    }

    private(set) var sections: [NotificationFeedDaySection] = []
    private(set) var sourceItemCount = 0
    private(set) var sourceUnreadCount = 0
    private(set) var isSourceRebuilding = false

    @ObservationIgnored private var sourceItems: [MobileNotificationFeedItem] = []
    @ObservationIgnored private var referenceDate: Date
    @ObservationIgnored private var calendar: Calendar
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var rebuildRevision = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

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
        sourceRevision &+= 1
        sourceItemCount = items.count
        sourceUnreadCount = items.lazy.filter { !$0.isRead }.count
        sections = []
        isSourceRebuilding = true
        scheduleRebuild()
    }

    func waitForPendingRebuild() async {
        await rebuildTask?.value
    }

    /// Debounces query changes and cancels superseded work. Stale rows are
    /// removed before the async rebuild starts, and results publish only while
    /// both captured revisions still match the current projection.
    private func scheduleRebuild(debounce: Duration? = nil) {
        rebuildRevision &+= 1
        let requestedRebuildRevision = rebuildRevision
        let requestedSourceRevision = sourceRevision
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedFilter = filter
        let requestedReferenceDate = referenceDate
        let requestedCalendar = calendar
        let requestedSourceItems = sourceItems

        sections = []
        isSourceRebuilding = true

        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if let debounce {
                do {
                    try await ContinuousClock().sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                return NotificationFeedProjection.build(
                    items: requestedSourceItems,
                    filter: requestedFilter,
                    query: query,
                    referenceDate: requestedReferenceDate,
                    calendar: requestedCalendar
                )
            }
            let output = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard
                !Task.isCancelled,
                let output,
                let self,
                self.rebuildRevision == requestedRebuildRevision,
                self.sourceRevision == requestedSourceRevision
            else {
                return
            }

            self.sections = output.sections
            self.isSourceRebuilding = false
        }
    }

    nonisolated private static let maxSearchableCharactersPerItem = 8_192

    nonisolated private static func build(
        items: [MobileNotificationFeedItem],
        filter: MobileNotificationFeedFilter,
        query: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> NotificationFeedProjectionOutput? {
        let today = calendar.startOfDay(for: referenceDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var sections: [NotificationFeedDaySection] = []
        sections.reserveCapacity(min(items.count, 8))
        var currentDay: Date?
        var currentItems: [MobileNotificationFeedItem] = []

        func flushCurrentSection() {
            guard let day = currentDay, !currentItems.isEmpty else { return }
            let kind: NotificationFeedDaySection.Kind
            if calendar.isDate(day, inSameDayAs: today) {
                kind = .today
            } else if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) {
                kind = .yesterday
            } else {
                kind = .dated
            }
            sections.append(NotificationFeedDaySection(
                id: day,
                kind: kind,
                items: currentItems
            ))
            currentItems = []
        }

        for item in items {
            guard !Task.isCancelled else { return nil }
            if filter == .unread, item.isRead {
                continue
            }
            if !query.isEmpty, !matchesSearchQuery(item: item, query: query) {
                continue
            }
            let day = calendar.startOfDay(for: item.createdAt)
            if let currentDay, currentDay != day {
                flushCurrentSection()
            }
            currentDay = day
            currentItems.append(item)
        }
        guard !Task.isCancelled else { return nil }
        flushCurrentSection()
        return NotificationFeedProjectionOutput(
            sections: sections
        )
    }

    nonisolated private static func matchesSearchQuery(
        item: MobileNotificationFeedItem,
        query: String
    ) -> Bool {
        var remainingCharacters = maxSearchableCharactersPerItem
        for field in [
            item.title,
            item.subtitle,
            item.body,
            item.workspaceTitle,
            item.surfaceTitle,
            item.macDisplayName,
        ].compactMap(\.self) {
            guard !Task.isCancelled else { return false }
            guard remainingCharacters > 0 else { return false }
            let limitedField = String(field.prefix(remainingCharacters))
            if limitedField.localizedStandardContains(query) {
                return true
            }
            remainingCharacters -= limitedField.count
        }
        return false
    }
}

private struct NotificationFeedProjectionOutput: Sendable {
    let sections: [NotificationFeedDaySection]
}
