import Foundation

/// The hover card's running times ("12s", "4m 12s", "1h 3m") and when each next changes its
/// text: the card arms one deadline for that change, never a periodic tick.
extension WorkspaceHoverCardContent {
    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// How long since `date`, live on the card: "12s", "4m 12s", "1h 3m"; at least one second,
    /// also for a start ahead of this clock (another machine's daemon).
    static func elapsed(since date: Date, now: Date) -> String {
        elapsedFormatter.string(from: shownElapsed(now.timeIntervalSince(date))) ?? ""
    }

    /// `text · 4m 12s` for a running fact, else `text`.
    static func withElapsed(_ text: String, since: Date?, now: Date) -> String {
        guard let since else { return text }
        return text + " · " + elapsed(since: since, now: now)
    }

    /// The seconds ``elapsed(since:now:)`` shows: whole seconds under an hour ("4m 12s"), whole
    /// minutes under a day ("1h 3m"), whole hours after ("2d 4h"), so the text changes only on a
    /// boundary of its last unit, whatever the formatter's rounding.
    static func shownElapsed(_ seconds: TimeInterval) -> TimeInterval {
        let whole = max(1, seconds.rounded(.down))
        let unit = elapsedUnit(whole)
        return (whole / unit).rounded(.down) * unit
    }

    /// How long until ``elapsed(since:now:)`` next reads differently: the next boundary of its
    /// last shown unit (a start ahead of this clock reads "1s" until two seconds have passed).
    static func nextElapsedChange(since date: Date, now: Date) -> TimeInterval {
        let seconds = now.timeIntervalSince(date)
        let unit = elapsedUnit(max(1, seconds.rounded(.down)))
        let boundary = max(2, ((seconds / unit).rounded(.down) + 1) * unit)
        return boundary - seconds
    }

    /// The last unit the running time shows for `seconds`.
    private static func elapsedUnit(_ seconds: TimeInterval) -> TimeInterval {
        seconds < 3600 ? 1 : seconds < 86_400 ? 60 : 3600
    }
}
