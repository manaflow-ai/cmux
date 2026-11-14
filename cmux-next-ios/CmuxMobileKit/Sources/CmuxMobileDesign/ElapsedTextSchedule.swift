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
            let next = elapsed.isFinite ? Int(Swift.max(Swift.min(elapsed, 1e9), -1e9)) + 1 : 0
            second = Swift.max(next, schedule.quietSeconds)
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

/// `.periodic(from: from, by: 1)` that stops after its first tick at or past
/// `until`: a countdown ("Resend in 0:12") whose text no longer changes once
/// it reaches its end ("Resend code") draws that text once, not every second.
public struct CountdownSchedule: TimelineSchedule, Sendable {
    public let from: Date
    public let until: Date

    public init(from: Date, until: Date) {
        self.from = from
        self.until = until
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(ticks: PeriodicTimelineSchedule(from: from, by: 1).entries(from: startDate, mode: mode), until: until)
    }

    public struct Entries: Sequence, IteratorProtocol {
        var ticks: PeriodicTimelineSchedule.Entries
        let until: Date
        var ended = false

        public mutating func next() -> Date? {
            guard !ended, let date = ticks.next() else { return nil }
            if date >= until { ended = true }
            return date
        }
    }
}
