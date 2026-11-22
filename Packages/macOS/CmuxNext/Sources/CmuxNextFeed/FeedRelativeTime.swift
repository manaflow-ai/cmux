import Foundation

/// Compact relative times ("40s", "3m", "2h", "1d"), localized by the
/// system formatter. Rendered against `FeedModel.now`, which advances only
/// on events and user actions, so nothing ticks while the panel is idle.
nonisolated enum FeedRelativeTime {
    static func string(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        switch seconds {
        case ..<60: formatter.allowedUnits = [.second]
        case ..<3_600: formatter.allowedUnits = [.minute]
        case ..<86_400: formatter.allowedUnits = [.hour]
        default: formatter.allowedUnits = [.day]
        }
        return formatter.string(from: seconds.rounded(.down)) ?? ""
    }
}
