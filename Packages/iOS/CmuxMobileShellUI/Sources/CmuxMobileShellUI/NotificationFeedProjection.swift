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

nonisolated let notificationFeedProjectionMaxSourceItemCount = MobileNotificationFeedAggregation.maxItemCount
nonisolated let notificationFeedProjectionMaxSearchQueryUnicodeScalars = MobileSearchQueryBounds().maxUnicodeScalars
nonisolated let notificationFeedProjectionMaxSearchQueryUTF8Bytes = MobileSearchQueryBounds().maxUTF8Bytes
nonisolated private let notificationFeedProjectionMaxMetadataSearchableCharactersPerField = 512
nonisolated private let notificationFeedProjectionMaxTitleSearchableCharacters = 1_024
nonisolated private let notificationFeedProjectionMaxSubtitleSearchableCharacters = 2_048
nonisolated private let notificationFeedProjectionMaxBodySearchableCharacters = 8_192

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
            let normalized = searchQueryBounds.boundedEditingText(searchText)
            if normalized.didChange {
                searchText = normalized.value
            }
            guard normalized.value != oldValue else { return }
            scheduleRebuild(
                debounce: notificationFeedProjectionNormalizedSearchQuery(normalized.value).isEmpty
                    ? nil
                    : .milliseconds(200)
            )
        }
    }

    private(set) var sections: [NotificationFeedDaySection] = []
    private(set) var sourceItemCount = 0
    private(set) var sourceUnreadCount = 0
    private(set) var isSourceRebuilding = false
    private(set) var hasStaleSourceSections = false

    @ObservationIgnored private var sourceItems: [MobileNotificationFeedItem] = []
    @ObservationIgnored private var referenceDate: Date
    @ObservationIgnored private var calendar: Calendar
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var rebuildRevision = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private let searchQueryBounds = MobileSearchQueryBounds()

    init(referenceDate: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    func update(
        items: [MobileNotificationFeedItem],
        referenceDate: Date = .now
    ) {
        let boundedItems = notificationFeedProjectionBoundedSourceItems(items)
        guard sourceItems != boundedItems || self.referenceDate != referenceDate else { return }
        sourceItems = boundedItems
        self.referenceDate = referenceDate
        sourceRevision &+= 1
        sourceItemCount = boundedItems.count
        sourceUnreadCount = boundedItems.lazy.filter { !$0.isRead }.count
        hasStaleSourceSections = !sections.isEmpty
        isSourceRebuilding = true
        scheduleRebuild()
    }

    func waitForPendingRebuild() async {
        await rebuildTask?.value
    }

    /// Debounces query changes and cancels superseded work. The last completed
    /// sections stay visible during rebuilds, and results publish atomically
    /// only while both captured revisions still match the current projection.
    private func scheduleRebuild(debounce: Duration? = nil) {
        rebuildRevision &+= 1
        let requestedRebuildRevision = rebuildRevision
        let requestedSourceRevision = sourceRevision
        let query = notificationFeedProjectionNormalizedSearchQuery(searchText)
        let requestedFilter = filter
        let requestedReferenceDate = referenceDate
        let requestedCalendar = calendar
        let requestedSourceItems = sourceItems

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
                return notificationFeedProjectionBuild(
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
            self.hasStaleSourceSections = false
            self.isSourceRebuilding = false
        }
    }

}

nonisolated private func notificationFeedProjectionBoundedSourceItems(
    _ items: [MobileNotificationFeedItem]
) -> [MobileNotificationFeedItem] {
    guard items.count > notificationFeedProjectionMaxSourceItemCount else { return items }
    return Array(items.prefix(notificationFeedProjectionMaxSourceItemCount))
}

nonisolated private func notificationFeedProjectionNormalizedSearchQuery(_ value: String) -> String {
    MobileSearchQueryBounds().normalizedFilterText(value).value
}

nonisolated private func notificationFeedProjectionBuild(
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
        if !query.isEmpty, !notificationFeedProjectionMatchesSearchQuery(item: item, query: query) {
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

nonisolated private func notificationFeedProjectionMatchesSearchQuery(
    item: MobileNotificationFeedItem,
    query: String
) -> Bool {
    for field in [
        item.workspaceTitle,
        item.surfaceTitle,
        item.macDisplayName,
    ] {
        guard !Task.isCancelled else { return false }
        if notificationFeedProjectionBoundedFieldContains(
            field,
            query: query,
            maxCharacters: notificationFeedProjectionMaxMetadataSearchableCharactersPerField
        ) {
            return true
        }
    }

    if notificationFeedProjectionBoundedFieldContains(
        item.title,
        query: query,
        maxCharacters: notificationFeedProjectionMaxTitleSearchableCharacters
    ) {
        return true
    }
    guard !Task.isCancelled else { return false }
    if notificationFeedProjectionBoundedFieldContains(
        item.subtitle,
        query: query,
        maxCharacters: notificationFeedProjectionMaxSubtitleSearchableCharacters
    ) {
        return true
    }
    guard !Task.isCancelled else { return false }
    if notificationFeedProjectionBoundedFieldContains(
        item.body,
        query: query,
        maxCharacters: notificationFeedProjectionMaxBodySearchableCharacters
    ) {
        return true
    }
    return false
}

nonisolated private func notificationFeedProjectionBoundedFieldContains(
    _ field: String?,
    query: String,
    maxCharacters: Int
) -> Bool {
    guard let field, maxCharacters > 0 else { return false }
    let end = field.index(
        field.startIndex,
        offsetBy: maxCharacters,
        limitedBy: field.endIndex
    ) ?? field.endIndex
    return field.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        range: field.startIndex..<end,
        locale: .autoupdatingCurrent
    ) != nil
}
