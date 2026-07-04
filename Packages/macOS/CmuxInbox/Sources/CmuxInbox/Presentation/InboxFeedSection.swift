public import Foundation

/// Date-bucketed group of inbox rows for feed-style rendering.
public struct InboxFeedSection: Equatable, Identifiable, Sendable {
    /// Relative-recency bucket. Display labels are localized by the UI layer.
    public enum Bucket: String, CaseIterable, Equatable, Sendable {
        case today
        case yesterday
        case thisWeek
        case earlier
    }

    /// Section bucket.
    public let bucket: Bucket
    /// Rows in the section, newest first.
    public let rows: [InboxRowSnapshot]

    /// Stable identity.
    public var id: String { bucket.rawValue }

    /// Creates a feed section.
    public init(bucket: Bucket, rows: [InboxRowSnapshot]) {
        self.bucket = bucket
        self.rows = rows
    }
}

extension InboxPresentationModel {
    /// Groups rows into date buckets, preserving row order inside each bucket
    /// and emitting buckets in recency order with empty buckets omitted.
    /// - Parameters:
    ///   - rows: Rows sorted newest first.
    ///   - now: Reference time, injected for testability.
    ///   - calendar: Calendar used for day boundaries.
    public func feedSections(
        rows: [InboxRowSnapshot],
        now: Date,
        calendar: Calendar = .current
    ) -> [InboxFeedSection] {
        var grouped: [InboxFeedSection.Bucket: [InboxRowSnapshot]] = [:]
        for row in rows {
            grouped[Self.bucket(for: row.timestamp, now: now, calendar: calendar), default: []].append(row)
        }
        return InboxFeedSection.Bucket.allCases.compactMap { bucket in
            guard let rows = grouped[bucket], !rows.isEmpty else { return nil }
            return InboxFeedSection(bucket: bucket, rows: rows)
        }
    }

    private static func bucket(
        for timestamp: Date,
        now: Date,
        calendar: Calendar
    ) -> InboxFeedSection.Bucket {
        // Future-dated events (clock skew, caller-supplied timestamps) stay in
        // the most recent bucket instead of leaking into "This Week".
        if timestamp > now || calendar.isDate(timestamp, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(timestamp, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), timestamp > weekAgo {
            return .thisWeek
        }
        return .earlier
    }
}
