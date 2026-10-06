import Foundation
@preconcurrency import Sparkle

/// What the update popover says about an available update: one readable line in
/// place of the raw version string, and the first few changes from the feed.
struct UpdateSummary: Equatable {
    /// The most changes listed inline before "and N more".
    static let maxInlineChanges = 5

    /// "Nightly · Today at 12:20 PM · 23 changes" or "0.65.1 · Oct 5".
    let headline: String
    /// Up to ``maxInlineChanges`` change titles from the feed description.
    let changes: [String]
    /// Changes the feed counted but the popover does not list.
    let remainingCount: Int

    init(item: SUAppcastItem, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        self.init(
            displayVersion: item.displayVersionString,
            date: item.date,
            itemDescription: item.itemDescription,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
    }

    init(
        displayVersion: String,
        date: Date?,
        itemDescription: String?,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let feed = Self.parse(itemDescription ?? "")
        changes = Array(feed.titles.prefix(Self.maxInlineChanges))
        remainingCount = feed.total - changes.count

        let isNightly = displayVersion.localizedCaseInsensitiveContains("nightly")
        var parts: [String] = []
        if isNightly {
            parts.append(String(localized: "update.popover.channel.nightly", defaultValue: "Nightly"))
        } else {
            parts.append(displayVersion)
        }
        if let date {
            parts.append(isNightly
                ? Self.nightlyDate(date, now: now, locale: locale, timeZone: timeZone)
                : Self.stableDate(date, locale: locale, timeZone: timeZone))
        }
        if feed.total > 0 {
            let total = feed.total
            parts.append(String(localized: "update.popover.changeCount", defaultValue: "\(total) changes"))
        }
        headline = parts.joined(separator: " · ")
    }

    /// Reads the plain-text summary `scripts/ci/nightly_release_notes.py` writes
    /// into the feed item's `<description>`: up to five "Title (#123)" lines,
    /// then "and N more" and "Infrastructure: N" when they apply. Infrastructure
    /// PRs are not counted as changes, and the empty-range sentences list none.
    static func parse(_ description: String) -> (titles: [String], total: Int) {
        var titles: [String] = []
        var more = 0
        for rawLine in description.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("Infrastructure:") || line.hasPrefix("No product PRs") || line.hasPrefix("See the release page") {
                continue
            }
            if let count = capture(#"^and (\d+) more$"#, in: line).flatMap({ Int($0) }) {
                more += count
                continue
            }
            let title = line.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
            if !title.isEmpty {
                titles.append(title)
            }
        }
        return (titles, titles.count + more)
    }

    private static func nightlyDate(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) {
            formatter.dateStyle = .medium
            formatter.doesRelativeDateFormatting = true
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        }
        return formatter.string(from: date)
    }

    private static func stableDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
