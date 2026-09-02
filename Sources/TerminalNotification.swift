import CmuxNotifications
import CmuxSettings
import Foundation

struct TerminalNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let correlationKey: String?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    var replyShape: TerminalNotificationReplyShape = .none
    var soundContext: NotificationSoundOverrideContext?

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        correlationKey: String? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        replyShape: TerminalNotificationReplyShape = .none,
        soundContext: NotificationSoundOverrideContext? = nil
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.replyShape = replyShape
        self.soundContext = soundContext
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    /// Matches a clear without letting live-owner expansion cross a confined notification's workspace boundary.
    func matchesClear(tabId targetTabId: UUID, liveTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard let targetSurfaceId else {
            let matchesWorkspace = tabId == targetTabId || (retargetsToLiveSurfaceOwner && tabId == liveTabId)
            return matchesWorkspace && surfaceId == nil && panelId == nil
        }
        guard surfaceId == targetSurfaceId || panelId == targetSurfaceId else {
            return false
        }
        // A retargetable notification is owned by the globally unique surface,
        // not by the workspace in which it happened to be stored when it was
        // delivered. This lets a completion clear a banner that was recorded
        // under the pane's previous workspace after a move.
        return retargetsToLiveSurfaceOwner || tabId == targetTabId
    }
}

/// Shared presentation helpers for notifications, used by every notification
/// surface (menu-bar dropdown, titlebar popover, in-app page) so the icon and
/// timestamp treatment stay identical across them (cmux shared-behavior policy).
/// Pure and Foundation-only so it is unit-testable without a UI or a live clock.
enum NotificationPresentation {
    /// SF Symbol name for a notification's leading icon chip. Reply-capable
    /// notifications read as a reply glyph; everything else uses the bell.
    static func symbolName(for notification: TerminalNotification) -> String {
        switch notification.replyShape {
        case .text:
            return "arrowshape.turn.up.left.fill"
        case .none:
            return "bell.fill"
        }
    }

    /// Time bucket a notification belongs to when the list is grouped by
    /// recency. Cases are ordered newest-first for display.
    enum TimeBucket: Int, CaseIterable, Sendable {
        case today
        case yesterday
        case earlier

        /// Localized section-header title.
        var title: String {
            switch self {
            case .today:
                return String(localized: "notifications.group.today", defaultValue: "Today")
            case .yesterday:
                return String(localized: "notifications.group.yesterday", defaultValue: "Yesterday")
            case .earlier:
                return String(localized: "notifications.group.earlier", defaultValue: "Earlier")
            }
        }
    }

    /// A run of notifications sharing one time bucket, for grouped rendering.
    struct Group: Identifiable, Sendable {
        let bucket: TimeBucket
        let notifications: [TerminalNotification]
        var id: Int { bucket.rawValue }
        var title: String { bucket.title }
    }

    /// Short, localized relative timestamp (e.g. "now", "2 min. ago",
    /// "yesterday"). More scannable than an absolute clock time; the absolute
    /// time stays available in each surface's tooltip.
    ///
    /// `dateTimeStyle = .named` returns a localized "now" for near-zero
    /// differences, so no custom string is needed. The date is clamped to
    /// `now` first so minor clock skew (a notification stamped a beat in the
    /// future) reads as "now" rather than "in 3 seconds".
    static func relativeTimeString(for date: Date, relativeTo now: Date = Date()) -> String {
        let clamped = min(date, now)
        // RelativeDateTimeFormatter is a non-Sendable class; build a fresh one
        // per call rather than sharing mutable global state across actors.
        // Call sites are infrequent (menu rebuild, popover open), so the cost
        // is immaterial.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: clamped, relativeTo: now)
    }

    /// The recency bucket for a single notification, computed relative to the
    /// supplied `now` (injectable so it is testable without the live clock).
    static func timeBucket(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> TimeBucket {
        let startOfToday = calendar.startOfDay(for: now)
        // Any time today — or a slightly-future timestamp from clock skew —
        // counts as "today".
        if date >= startOfToday { return .today }
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return .earlier
        }
        return date >= startOfYesterday ? .yesterday : .earlier
    }

    /// Groups notifications into ordered `Today / Yesterday / Earlier` sections,
    /// preserving the input order (newest-first) within each section and
    /// omitting empty sections.
    static func grouped(
        _ notifications: [TerminalNotification],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        var byBucket: [TimeBucket: [TerminalNotification]] = [:]
        for notification in notifications {
            let bucket = timeBucket(for: notification.createdAt, now: now, calendar: calendar)
            byBucket[bucket, default: []].append(notification)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let items = byBucket[bucket], !items.isEmpty else { return nil }
            return Group(bucket: bucket, notifications: items)
        }
    }
}
