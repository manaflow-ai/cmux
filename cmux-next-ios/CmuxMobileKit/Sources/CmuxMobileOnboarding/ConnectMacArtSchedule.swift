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
        Entries(mode: mode, interval: interval, next: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let mode: Mode
        let interval: TimeInterval
        var next: Date?

        mutating func next() -> Date? {
            guard let date = next else { return nil }
            switch mode {
            case .still:
                next = nil
            case .riding:
                next = date.addingTimeInterval(interval)
            case let .pulses(since, period, active):
                next = Self.after(date, since: since, period: period, active: active, interval: interval)
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
            let elapsed = date.timeIntervalSince(since)
            let cycle = (elapsed / period).rounded(.down)
            let cycleStart = since.addingTimeInterval(cycle * period)
            let u = elapsed - cycle * period
            if u < active - epsilon {
                let pulseEnd = cycleStart.addingTimeInterval(active)
                let step = date.addingTimeInterval(interval)
                return step < pulseEnd.addingTimeInterval(-epsilon) ? step : pulseEnd
            }
            return cycleStart.addingTimeInterval(period)
        }
    }
}
