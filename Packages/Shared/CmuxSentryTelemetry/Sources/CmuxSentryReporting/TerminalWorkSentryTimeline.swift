import Foundation
import Sentry

/// Reads the public wire representation used for previous-process watchdog events.
struct TerminalWorkSentryTimeline {
    func breadcrumbs(in event: Event) -> [Breadcrumb] {
        if let breadcrumbs = event.breadcrumbs, !breadcrumbs.isEmpty {
            return Array(breadcrumbs.suffix(100))
        }
        // serialize() supplies a timestamp when it is missing. Do not let that
        // turn an event with no capture time into apparently attributable work.
        guard event.timestamp != nil,
              let rows = event.serialize()["breadcrumbs"] as? [[String: Any]] else { return [] }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSeconds = ISO8601DateFormatter()
        return rows.suffix(100).compactMap { row in
            guard row["category"] as? String == "terminal.work",
                  let data = row["data"] as? [String: Any] else { return nil }
            let timestamp: Date?
            if let seconds = row["timestamp"] as? Double, seconds.isFinite {
                timestamp = Date(timeIntervalSince1970: seconds)
            } else if let text = row["timestamp"] as? String {
                timestamp = fractional.date(from: text) ?? wholeSeconds.date(from: text)
            } else {
                timestamp = nil
            }
            guard let timestamp else { return nil }
            let breadcrumb = Breadcrumb(level: .info, category: "terminal.work")
            breadcrumb.timestamp = timestamp
            breadcrumb.replaceData(data)
            return breadcrumb
        }
    }
}
