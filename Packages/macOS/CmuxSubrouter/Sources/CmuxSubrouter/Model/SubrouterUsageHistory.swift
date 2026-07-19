public import Foundation

/// A rolling, persistable history of quota-window usage samples, keyed by
/// account and window name. The store appends a sample after each
/// successful usage refresh; the panel renders the series as sparklines so
/// subscription burn is visible over time, not just as an instantaneous
/// percentage.
public struct SubrouterUsageHistory: Sendable, Equatable, Codable {
    /// One observation of a window's used percentage.
    public struct Sample: Sendable, Equatable, Codable {
        /// When the sample was recorded.
        public let recordedAt: Date
        /// The window's used percentage at that time (0–100).
        public let usedPercent: Double

        /// Creates a sample.
        public init(recordedAt: Date, usedPercent: Double) {
            self.recordedAt = recordedAt
            self.usedPercent = usedPercent
        }
    }

    /// Samples newer than this are dropped at record time relative to the
    /// previous sample, unless usage moved noticeably — bounds growth while
    /// catching real movement between poll ticks.
    public static let minimumSampleSpacing: TimeInterval = 10 * 60
    /// Movement (in percent points) that forces a sample despite spacing.
    public static let significantDelta: Double = 1.0
    /// Cap per series; oldest samples fall off.
    public static let maximumSamplesPerSeries = 96
    /// Samples older than this are pruned on record.
    public static let retention: TimeInterval = 7 * 24 * 3600

    private var seriesByKey: [String: [Sample]]

    /// Creates an empty history.
    public init() {
        seriesByKey = [:]
    }

    /// The series key for an account's window.
    public static func key(accountID: String, windowName: String) -> String {
        "\(accountID)\u{1F}\(windowName)"
    }

    /// The recorded samples for an account window, oldest first.
    public func samples(accountID: String, windowName: String) -> [Sample] {
        seriesByKey[Self.key(accountID: accountID, windowName: windowName)] ?? []
    }

    /// Records the current usage snapshot at `now`. Returns `true` when any
    /// series changed (callers persist only then).
    @discardableResult
    public mutating func record(
        usageStatuses: [SubrouterAccountUsageStatus],
        now: Date
    ) -> Bool {
        var changed = false
        for account in usageStatuses {
            for window in account.windows {
                let key = Self.key(accountID: account.id, windowName: window.name)
                var series = seriesByKey[key] ?? []
                if let last = series.last {
                    let spaced = now.timeIntervalSince(last.recordedAt) >= Self.minimumSampleSpacing
                    let moved = abs(window.usedPercent - last.usedPercent) >= Self.significantDelta
                    guard spaced || moved else { continue }
                }
                series.append(Sample(recordedAt: now, usedPercent: window.usedPercent))
                let cutoff = now.addingTimeInterval(-Self.retention)
                series.removeAll { $0.recordedAt < cutoff }
                if series.count > Self.maximumSamplesPerSeries {
                    series.removeFirst(series.count - Self.maximumSamplesPerSeries)
                }
                seriesByKey[key] = series
                changed = true
            }
        }
        return changed
    }

    /// Loads a persisted history, or an empty one for missing/undecodable
    /// data.
    public static func load(from url: URL) -> SubrouterUsageHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(SubrouterUsageHistory.self, from: data) else {
            return SubrouterUsageHistory()
        }
        return history
    }

    /// Persists the history, creating parent directories as needed.
    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
