import Foundation

// MARK: - Sort

/// Sort applied inside the Vault's recency ("All") day sections.
enum VaultSessionSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case lastActivity
    case created
    case duration
    case folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastActivity:
            return String(localized: "sessionIndex.sort.lastActivity", defaultValue: "Last activity")
        case .created:
            return String(localized: "sessionIndex.sort.created", defaultValue: "Created")
        case .duration:
            return String(localized: "sessionIndex.sort.duration", defaultValue: "Duration")
        case .folder:
            return String(localized: "sessionIndex.sort.folder", defaultValue: "Folder")
        }
    }

    /// Comparator for entries inside one day bucket. Deterministic: ties fall
    /// back to recency, then to the stable entry id.
    nonisolated func areInIncreasingOrder(_ lhs: SessionEntry, _ rhs: SessionEntry) -> Bool {
        switch self {
        case .lastActivity:
            break
        case .created:
            let l = lhs.created ?? lhs.modified
            let r = rhs.created ?? rhs.modified
            if l != r { return l > r }
        case .duration:
            let l = Self.sessionDuration(of: lhs)
            let r = Self.sessionDuration(of: rhs)
            if l != r { return l > r }
        case .folder:
            let l = lhs.cwd ?? ""
            let r = rhs.cwd ?? ""
            if l != r { return l.localizedCaseInsensitiveCompare(r) == .orderedAscending }
        }
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        return lhs.id < rhs.id
    }

    nonisolated static func sessionDuration(of entry: SessionEntry) -> TimeInterval {
        guard let created = entry.created else { return 0 }
        return max(0, entry.modified.timeIntervalSince(created))
    }
}

// MARK: - Filter

/// Filter state for the recency ("All") view. Pure value; application is a
/// pure function so it is directly testable.
struct VaultSessionFilter: Equatable, Sendable {
    enum Liveness: String, CaseIterable, Identifiable, Sendable {
        case all
        case live
        case ended

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:
                return String(localized: "sessionIndex.filter.status.all", defaultValue: "All statuses")
            case .live:
                return String(localized: "sessionIndex.filter.status.live", defaultValue: "Live")
            case .ended:
                return String(localized: "sessionIndex.filter.status.ended", defaultValue: "Ended")
            }
        }
    }

    enum DatePreset: String, CaseIterable, Identifiable, Sendable {
        case anyTime
        case today
        case last7Days
        case last30Days

        var id: String { rawValue }

        var label: String {
            switch self {
            case .anyTime:
                return String(localized: "sessionIndex.filter.date.anyTime", defaultValue: "Any time")
            case .today:
                return String(localized: "sessionIndex.filter.date.today", defaultValue: "Today")
            case .last7Days:
                return String(localized: "sessionIndex.filter.date.last7Days", defaultValue: "Last 7 days")
            case .last30Days:
                return String(localized: "sessionIndex.filter.date.last30Days", defaultValue: "Last 30 days")
            }
        }

        /// Earliest `modified` still inside the preset window; nil = unbounded.
        nonisolated func startDate(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .anyTime:
                return nil
            case .today:
                return calendar.startOfDay(for: now)
            case .last7Days:
                return calendar.date(byAdding: .day, value: -7, to: now)
            case .last30Days:
                return calendar.date(byAdding: .day, value: -30, to: now)
            }
        }
    }

    /// nil = all agents. Values are `SessionAgent.rawValue`s.
    var agentID: String?
    var liveness: Liveness = .all
    /// Exact cwd match; nil = all folders.
    var folder: String?
    var datePreset: DatePreset = .anyTime

    var isActive: Bool {
        agentID != nil || liveness != .all || folder != nil || datePreset != .anyTime
    }

    /// Core predicate with the date boundary already resolved — `build`
    /// resolves it once per pass instead of once per entry.
    nonisolated func matches(
        _ entry: SessionEntry,
        liveKeys: Set<String>,
        dateStart: Date?
    ) -> Bool {
        if let agentID, entry.agent.rawValue != agentID { return false }
        if let folder, (entry.cwd ?? "") != folder { return false }
        if let dateStart, entry.modified < dateStart { return false }
        switch liveness {
        case .all:
            return true
        case .live:
            return liveKeys.contains(VaultLiveSessionKeys.key(for: entry))
        case .ended:
            return !liveKeys.contains(VaultLiveSessionKeys.key(for: entry))
        }
    }

    nonisolated func matches(
        _ entry: SessionEntry,
        liveKeys: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        matches(
            entry,
            liveKeys: liveKeys,
            dateStart: datePreset.startDate(now: now, calendar: calendar)
        )
    }
}

// MARK: - Row accessory

/// Extra display facts a recency/search row shows beyond the base
/// `SessionEntry` (which stays a pure disk-index record).
struct VaultSessionRowAccessory: Equatable, Sendable {
    let liveStatus: VaultSessionLiveStatus
    let detail: String?
    let messageCount: Int?

    /// True when the row renders a second (subtitle) line. The table height
    /// calculator must agree with `SessionRow`'s layout on this.
    var hasSubtitle: Bool { detail != nil || messageCount != nil }

    nonisolated static func detailText(for entry: SessionEntry) -> String? {
        var parts: [String] = []
        if let basename = entry.cwdBasename, !basename.isEmpty {
            parts.append(basename)
        }
        if let branch = entry.gitBranch, !branch.isEmpty {
            parts.append(branch)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func make(
        for entry: SessionEntry,
        liveKeys: Set<String>,
        now: Date
    ) -> VaultSessionRowAccessory {
        VaultSessionRowAccessory(
            liveStatus: VaultSessionLiveStatus.derive(
                isProcessRunning: liveKeys.contains(VaultLiveSessionKeys.key(for: entry)),
                lastActivity: entry.modified,
                now: now
            ),
            detail: detailText(for: entry),
            messageCount: entry.messageCount
        )
    }
}

// MARK: - Day keys

extension SectionKey {
    /// `day:<yyyy-MM-dd>` key for a recency day bucket. Not persisted and not
    /// user-reorderable, unlike `agent:`/`dir:` keys. Formats in the SAME
    /// calendar that produced the bucket so the key names the bucket's day
    /// regardless of the machine timezone.
    static func day(_ startOfDay: Date, calendar: Calendar) -> SectionKey {
        let style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone)
            .year().month().day()
        return SectionKey(raw: "day:" + startOfDay.formatted(style))
    }

    var isDayBucket: Bool { raw.hasPrefix("day:") }
}

// MARK: - Sections builder

/// Pure builder for the recency ("All") grouping: flat cross-agent entries
/// bucketed by calendar day of last activity, newest bucket first. Shared
/// shape with the History timeline work (issue #9127) — keep this free of
/// store references so both features can use it.
enum VaultRecencySections {
    /// Rows shown per day section before inline expansion.
    nonisolated static let collapsedRowLimit = 10
    /// Rows shown per day section after "Show more". Bounded so a single
    /// giant day cannot render thousands of hosted rows.
    nonisolated static let expandedRowLimit = 200

    nonisolated static func build(
        entries: [SessionEntry],
        filter: VaultSessionFilter,
        sort: VaultSessionSort,
        liveKeys: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> [IndexSection] {
        let dateStart = filter.datePreset.startDate(now: now, calendar: calendar)
        let visible = entries.filter {
            filter.matches($0, liveKeys: liveKeys, dateStart: dateStart)
        }
        guard !visible.isEmpty else { return [] }

        let buckets = Dictionary(grouping: visible) { entry in
            calendar.startOfDay(for: entry.modified)
        }
        return buckets.keys.sorted(by: >).map { dayStart in
            let dayEntries = (buckets[dayStart] ?? []).sorted(by: sort.areInIncreasingOrder)
            return IndexSection(
                key: .day(dayStart, calendar: calendar),
                title: dayTitle(for: dayStart, now: now, calendar: calendar),
                icon: .day,
                entries: dayEntries,
                accessories: accessories(for: dayEntries, liveKeys: liveKeys, now: now)
            )
        }
    }

    /// Accessory map for a batch of rows (also used by the search results
    /// section so both surfaces render identical row chrome).
    nonisolated static func accessories(
        for entries: [SessionEntry],
        liveKeys: Set<String>,
        now: Date
    ) -> [String: VaultSessionRowAccessory] {
        var accessories: [String: VaultSessionRowAccessory] = [:]
        accessories.reserveCapacity(entries.count)
        for entry in entries {
            accessories[entry.id] = VaultSessionRowAccessory.make(
                for: entry,
                liveKeys: liveKeys,
                now: now
            )
        }
        return accessories
    }

    nonisolated static func dayTitle(for dayStart: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if dayStart == today {
            return String(localized: "sessionIndex.day.today", defaultValue: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           dayStart == yesterday {
            return String(localized: "sessionIndex.day.yesterday", defaultValue: "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today),
           dayStart >= weekAgo, dayStart < today {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.calendar = calendar
            weekdayFormatter.locale = calendar.locale ?? .current
            weekdayFormatter.timeZone = calendar.timeZone
            weekdayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
            return weekdayFormatter.string(from: dayStart)
        }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = calendar.locale ?? .current
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: dayStart)
    }
}
