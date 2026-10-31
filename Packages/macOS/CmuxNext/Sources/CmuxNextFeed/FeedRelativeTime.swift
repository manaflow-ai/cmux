import Foundation

/// Compact relative times ("40s", "3m", "2h", "1d"), localized by the
/// system formatter. Rendered against `FeedModel.now`, which advances only
/// on events and user actions, so nothing ticks while the panel is idle.
nonisolated enum FeedRelativeTime {
    static func string(_ date: Date, now: Date) -> String {
        Formatter().string(date, now: now)
    }

    /// One system formatter per unit, made on first use: a list keeps one, so a render of many
    /// rows makes no formatter per row.
    nonisolated final class Formatter {
        private var byUnit: [NSCalendar.Unit.RawValue: DateComponentsFormatter] = [:]

        func string(_ date: Date, now: Date) -> String {
            let seconds = max(0, now.timeIntervalSince(date))
            let unit: NSCalendar.Unit = switch seconds {
            case ..<60: .second
            case ..<3_600: .minute
            case ..<86_400: .hour
            default: .day
            }
            return formatter(unit).string(from: seconds.rounded(.down)) ?? ""
        }

        private func formatter(_ unit: NSCalendar.Unit) -> DateComponentsFormatter {
            if let made = byUnit[unit.rawValue] { return made }
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [unit]
            byUnit[unit.rawValue] = formatter
            return formatter
        }
    }
}
