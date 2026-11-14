import Foundation
import SwiftUI

/// The redraws of a label that counts whole seconds up from `since` ("12s",
/// "· 1m 5s") and shows the same text for its first `quietSeconds`: the
/// moment it appears, then each whole second after `since` from the first
/// one past the quiet seconds. `.periodic(from: since, by: 1)` gives the
/// same text at the same moments, plus a redraw each second of the quiet
/// stretch that draws the same text again.
public struct ElapsedTextSchedule: TimelineSchedule, Sendable {
    public let since: Date
    public let quietSeconds: Int

    public init(since: Date, quietSeconds: Int = 0) {
        self.since = since
        self.quietSeconds = max(0, quietSeconds)
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(schedule: self, start: startDate)
    }

    /// The moment the label appears (its text is that moment's, as with the
    /// periodic schedule's whole second at or before it), then the whole
    /// seconds after `since` where the text can change.
    public struct Entries: Sequence, IteratorProtocol, Sendable {
        private let since: Date
        private var first: Date?
        private var second: Int

        init(schedule: ElapsedTextSchedule, start: Date) {
            since = schedule.since
            first = start
            let elapsed = start.timeIntervalSince(schedule.since).rounded(.down)
            // The first whole second after `start`, and none inside the quiet stretch.
            let next = elapsed.isFinite ? Int(max(min(elapsed, 1e9), -1e9)) + 1 : 0
            second = max(next, schedule.quietSeconds)
        }

        public mutating func next() -> Date? {
            if let date = first {
                first = nil
                return date
            }
            defer { second += 1 }
            return since.addingTimeInterval(TimeInterval(second))
        }
    }
}
