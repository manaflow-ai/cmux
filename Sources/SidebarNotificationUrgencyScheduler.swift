import Foundation
import CmuxSettings

struct SidebarNotificationSchedulerSnapshot: Equatable {
    var workspaceId: UUID
    var originalIndex: Int
    var unreadCount: Int
    var latestNotificationText: String?
    var latestNotificationCreatedAt: Date?
    var latestNotificationIsUnread: Bool
    var workspaceTitle: String
    var customDescription: String?
    var latestSubmittedMessage: String?
    var remoteDisplayTarget: String?
    var remoteConnectionState: String?
    var panelCount: Int
}

struct SidebarNotificationUrgency: Equatable {
    enum Band: Int, Equatable {
        case critical = 0
        case high = 1
        case medium = 2
        case low = 3

        var label: String {
            switch self {
            case .critical:
                "P0"
            case .high:
                "P1"
            case .medium:
                "P2"
            case .low:
                "P3"
            }
        }
    }

    enum Reason: Equatable {
        case blocked
        case failed
        case ready
        case smallWin
        case aged
        case unread
        case remote

        var localizedTitle: String {
            switch self {
            case .blocked:
                String(localized: "sidebar.notificationUrgency.reason.blocked", defaultValue: "Blocked")
            case .failed:
                String(localized: "sidebar.notificationUrgency.reason.failed", defaultValue: "Failed")
            case .ready:
                String(localized: "sidebar.notificationUrgency.reason.ready", defaultValue: "Ready")
            case .smallWin:
                String(localized: "sidebar.notificationUrgency.reason.smallWin", defaultValue: "Small")
            case .aged:
                String(localized: "sidebar.notificationUrgency.reason.aged", defaultValue: "Aging")
            case .unread:
                String(localized: "sidebar.notificationUrgency.reason.unread", defaultValue: "Unread")
            case .remote:
                String(localized: "sidebar.notificationUrgency.reason.remote", defaultValue: "Remote")
            }
        }
    }

    var workspaceId: UUID
    var band: Band
    var reason: Reason
    var score: Int

    var accessibilityText: String {
        String(
            format: String(localized: "sidebar.notificationUrgency.help", defaultValue: "Urgency %@: %@"),
            locale: .current,
            band.label,
            reason.localizedTitle
        )
    }

    func sidebarNotificationText(_ notificationText: String) -> String {
        String(
            format: String(localized: "sidebar.notificationUrgency.subtitleFormat", defaultValue: "%@ %@: %@"),
            locale: .current,
            band.label,
            reason.localizedTitle,
            notificationText
        )
    }
}

enum SidebarNotificationUrgencyScheduler {
    static func urgencyByWorkspaceId(
        snapshots: [SidebarNotificationSchedulerSnapshot],
        now: Date
    ) -> [UUID: SidebarNotificationUrgency] {
        Dictionary(uniqueKeysWithValues: scheduledItems(snapshots: snapshots, now: now, mode: .smartUrgency).map {
            ($0.snapshot.workspaceId, $0.urgency)
        })
    }

    static func orderedWorkspaceIds(
        snapshots: [SidebarNotificationSchedulerSnapshot],
        now: Date,
        mode: SidebarNotificationSchedulerMode = .smartUrgency,
        roundRobinCursor: UUID? = nil
    ) -> [UUID] {
        scheduledItems(
            snapshots: snapshots,
            now: now,
            mode: mode,
            roundRobinCursor: roundRobinCursor
        )
        .map(\.snapshot.workspaceId)
    }

    static func urgency(
        for snapshot: SidebarNotificationSchedulerSnapshot,
        now: Date
    ) -> SidebarNotificationUrgency? {
        evaluation(for: snapshot, now: now)?.urgency
    }

    private struct ScheduledItem {
        var snapshot: SidebarNotificationSchedulerSnapshot
        var urgency: SidebarNotificationUrgency
        var signals: Set<Signal>
        var latestNotificationCreatedAt: Date?
        var originalIndex: Int
        var roundRobinRank: Int
    }

    private enum Signal: Hashable {
        case blocked
        case failed
        case ready
        case smallWin
        case aged
        case unread
        case remote
    }

    private struct Evaluation {
        var urgency: SidebarNotificationUrgency
        var signals: Set<Signal>
    }

    private static func scheduledItems(
        snapshots: [SidebarNotificationSchedulerSnapshot],
        now: Date,
        mode: SidebarNotificationSchedulerMode,
        roundRobinCursor: UUID? = nil
    ) -> [ScheduledItem] {
        let roundRobinStartIndex = roundRobinStartIndex(
            snapshots: snapshots,
            cursor: roundRobinCursor
        )
        let snapshotCount = max(snapshots.count, 1)
        return snapshots.compactMap { snapshot in
            guard let evaluation = evaluation(for: snapshot, now: now) else { return nil }
            return ScheduledItem(
                snapshot: snapshot,
                urgency: evaluation.urgency,
                signals: evaluation.signals,
                latestNotificationCreatedAt: snapshot.latestNotificationCreatedAt,
                originalIndex: snapshot.originalIndex,
                roundRobinRank: (snapshot.originalIndex - roundRobinStartIndex + snapshotCount) % snapshotCount
            )
        }
        .sorted { lhs, rhs in
            precedes(lhs, rhs, mode: mode)
        }
    }

    private static func evaluation(
        for snapshot: SidebarNotificationSchedulerSnapshot,
        now: Date
    ) -> Evaluation? {
        let latestText = trimmed(snapshot.latestNotificationText)
        guard snapshot.unreadCount > 0 || snapshot.latestNotificationIsUnread else { return nil }

        let searchableText = [
            snapshot.workspaceTitle,
            snapshot.customDescription,
            latestText,
            snapshot.latestSubmittedMessage,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        var signals: Set<Signal> = []
        var score = 0.0

        if snapshot.unreadCount > 0 || snapshot.latestNotificationIsUnread {
            signals.insert(.unread)
            score += 80 + Double(min(snapshot.unreadCount, 5) * 4)
        }
        if remoteNeedsAttention(snapshot) {
            signals.insert(.remote)
            score += 130
        }
        if containsAny(searchableText, ["needs input", "approval", "approve", "blocked", "waiting for", "requires input", "question", "confirm", "permission"]) {
            signals.insert(.blocked)
            score += 160
        }
        if containsAny(searchableText, ["failed", "failure", "error", "exit code", "conflict", "denied", "missing", "crash", "rejected", "timed out"]) {
            signals.insert(.failed)
            score += 115
        }
        if containsAny(searchableText, ["ready", "done", "complete", "completed", "tests passed", "passed", "opened pr", "pull request", "review", "merge"]) {
            signals.insert(.ready)
            score += 90
        }
        if isSmallWin(snapshot: snapshot, searchableText: searchableText) {
            signals.insert(.smallWin)
            score += 45
        }
        if let createdAt = snapshot.latestNotificationCreatedAt {
            let ageSeconds = max(0, now.timeIntervalSince(createdAt))
            score += min(60, ageSeconds / 180)
            if ageSeconds >= 30 * 60 {
                signals.insert(.aged)
            }
        }

        return Evaluation(
            urgency: SidebarNotificationUrgency(
                workspaceId: snapshot.workspaceId,
                band: band(signals: signals),
                reason: reason(signals: signals),
                score: Int(score.rounded())
            ),
            signals: signals
        )
    }

    private static func roundRobinStartIndex(
        snapshots: [SidebarNotificationSchedulerSnapshot],
        cursor: UUID?
    ) -> Int {
        guard !snapshots.isEmpty,
              let cursor,
              let cursorIndex = snapshots.first(where: { $0.workspaceId == cursor })?.originalIndex
        else {
            return 0
        }
        return (cursorIndex + 1) % snapshots.count
    }

    private static func precedes(
        _ lhs: ScheduledItem,
        _ rhs: ScheduledItem,
        mode: SidebarNotificationSchedulerMode
    ) -> Bool {
        let lhsBlocked = isBlockedPriority(lhs)
        let rhsBlocked = isBlockedPriority(rhs)
        if lhsBlocked != rhsBlocked {
            return lhsBlocked
        }

        switch mode {
        case .smartUrgency:
            return smartPrecedes(lhs, rhs)
        case .blockedFirst:
            return arrivalPrecedes(lhs, rhs)
        case .smallWins:
            let lhsSmall = lhs.signals.contains(.smallWin)
            let rhsSmall = rhs.signals.contains(.smallWin)
            if lhsSmall != rhsSmall {
                return lhsSmall
            }
            return smartPrecedes(lhs, rhs)
        case .aging:
            return agePrecedes(lhs, rhs)
        case .roundRobin:
            if lhs.roundRobinRank != rhs.roundRobinRank {
                return lhs.roundRobinRank < rhs.roundRobinRank
            }
            return smartPrecedes(lhs, rhs)
        case .arrivalOrder:
            return arrivalPrecedes(lhs, rhs)
        }
    }

    private static func smartPrecedes(_ lhs: ScheduledItem, _ rhs: ScheduledItem) -> Bool {
        if lhs.urgency.band.rawValue != rhs.urgency.band.rawValue {
            return lhs.urgency.band.rawValue < rhs.urgency.band.rawValue
        }
        if lhs.urgency.score != rhs.urgency.score {
            return lhs.urgency.score > rhs.urgency.score
        }
        switch (lhs.latestNotificationCreatedAt, rhs.latestNotificationCreatedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    private static func agePrecedes(_ lhs: ScheduledItem, _ rhs: ScheduledItem) -> Bool {
        switch (lhs.latestNotificationCreatedAt, rhs.latestNotificationCreatedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return smartPrecedes(lhs, rhs)
        }
    }

    private static func arrivalPrecedes(_ lhs: ScheduledItem, _ rhs: ScheduledItem) -> Bool {
        switch (lhs.latestNotificationCreatedAt, rhs.latestNotificationCreatedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    private static func isBlockedPriority(_ item: ScheduledItem) -> Bool {
        item.signals.contains(.blocked) || item.signals.contains(.remote)
    }

    private static func band(signals: Set<Signal>) -> SidebarNotificationUrgency.Band {
        if signals.contains(.blocked) || signals.contains(.remote) {
            return .critical
        }
        if signals.contains(.failed) || (signals.contains(.ready) && signals.contains(.smallWin)) {
            return .high
        }
        if signals.contains(.ready) || signals.contains(.aged) {
            return .medium
        }
        return .low
    }

    private static func reason(signals: Set<Signal>) -> SidebarNotificationUrgency.Reason {
        if signals.contains(.blocked) { return .blocked }
        if signals.contains(.remote) { return .remote }
        if signals.contains(.failed) { return .failed }
        if signals.contains(.ready) { return .ready }
        if signals.contains(.smallWin) { return .smallWin }
        if signals.contains(.aged) { return .aged }
        return .unread
    }

    private static func isSmallWin(
        snapshot: SidebarNotificationSchedulerSnapshot,
        searchableText: String
    ) -> Bool {
        if containsAny(searchableText, ["small", "quick", "targeted", "bug", "fix", "docs", "typo", "lint", "test", "minor", "one-line"]) {
            return true
        }
        return (snapshot.latestSubmittedMessage?.count ?? Int.max) <= 220 && snapshot.panelCount <= 2
    }

    private static func remoteNeedsAttention(_ snapshot: SidebarNotificationSchedulerSnapshot) -> Bool {
        guard trimmed(snapshot.remoteDisplayTarget) != nil,
              let state = trimmed(snapshot.remoteConnectionState)?.lowercased()
        else {
            return false
        }
        return state == "connecting" || state == "reconnecting" || state == "disconnected"
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
