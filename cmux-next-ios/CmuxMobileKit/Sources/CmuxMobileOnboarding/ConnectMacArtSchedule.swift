import Foundation
import SwiftUI

/// When Connect your Mac's art draws a new frame (S6, `design/ios.md`).
///
/// - `riding`: every display frame (up to 60 a second) while the ride and
///   bloom play; `PairMacStep` ends it when the bloom settles.
/// - `pulses`: the wait's faint pulse plays for `active` seconds of every
///   `period`. Frames come only during a pulse, plus one at the moment it ends
///   (so the art draws its rest state), and none in the gap until the next
///   pulse starts. The old `.animation` schedule drew all of the gap too: 144
///   frames in each 2.4 s cycle where 91 change anything.
/// - `still`: one frame, nothing after it.
struct ConnectMacArtSchedule: TimelineSchedule, Equatable {
    enum Mode: Equatable {
        case still
        case riding
        case pulses(since: Date, period: TimeInterval, active: TimeInterval)
    }

    var mode: Mode
    var interval: TimeInterval = 1.0 / 60

    func entries(from startDate: Date, mode _: TimelineScheduleMode) -> Entries {
        Entries(mode: mode, interval: interval, upcoming: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let mode: Mode
        let interval: TimeInterval
        var upcoming: Date?

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            switch mode {
            case .still:
                upcoming = nil
            case .riding:
                upcoming = date.addingTimeInterval(interval)
            case let .pulses(since, period, active):
                upcoming = Self.after(date, since: since, period: period, active: active, interval: interval)
            }
            return date
        }

        /// The frame after `date`: the next display frame inside a pulse, the
        /// pulse's end once, then the next pulse's start. Always later than
        /// `date`, so the sequence never repeats a frame.
        static func after(_ date: Date, since: Date, period: TimeInterval, active: TimeInterval,
                          interval: TimeInterval) -> Date {
            // Tolerance for a frame landing on a pulse's end in floating point.
            let epsilon = 1e-6
            // Date arithmetic can put `date` a hair before the cycle boundary it
            // was computed from ((since + 2.4) - since < 2.4): take the later
            // cycle when its start is not after `date`, so a frame on a
            // boundary never resolves to itself.
            var cycle = (date.timeIntervalSince(since) / period).rounded(.down)
            if since.addingTimeInterval((cycle + 1) * period) <= date { cycle += 1 }
            let cycleStart = since.addingTimeInterval(cycle * period)
            let u = date.timeIntervalSince(cycleStart)
            let candidate: Date
            if u < active - epsilon {
                let pulseEnd = cycleStart.addingTimeInterval(active)
                let step = date.addingTimeInterval(interval)
                candidate = step < pulseEnd.addingTimeInterval(-epsilon) ? step : pulseEnd
            } else {
                candidate = cycleStart.addingTimeInterval(period)
            }
            // Never the same date again (the schedule would stall there).
            return candidate > date ? candidate : date.addingTimeInterval(interval)
        }
    }
}
