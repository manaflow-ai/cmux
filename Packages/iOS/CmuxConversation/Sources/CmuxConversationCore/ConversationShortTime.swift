import Foundation

/// Messages' short send times ("9:41 AM"), formatted once per minute.
///
/// Every message cell configure showed its send time (the swipe drawer's
/// label) through `Date.formatted`, an ICU format each time: 12% of a cell
/// configure on a cold scroll. A transcript shows the same few minutes over
/// and over, and the text depends only on the minute (every time zone's
/// offset has been a whole number of minutes since 1972; earlier dates are
/// formatted each time).
public struct ConversationShortTimeCache {
    /// Dates before this (1972-05-01 UTC) may fall in an offset with seconds.
    static let wholeMinuteOffsetsSince = Date(timeIntervalSince1970: 73_526_400)
    /// Entries kept before the cache starts over.
    static let capacity = 4096

    private var texts: [Int: String] = [:]
    private let format: (Date) -> String

    public init(format: @escaping (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) {
        self.format = format
    }

    /// `date` as `format` writes it.
    public mutating func text(for date: Date) -> String {
        guard date >= Self.wholeMinuteOffsetsSince else { return format(date) }
        let minute = Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
        if let text = texts[minute] { return text }
        if texts.count >= Self.capacity { texts.removeAll() }
        let text = format(date)
        texts[minute] = text
        return text
    }

    /// Forgets every time (the locale, time zone or clock format changed).
    public mutating func removeAll() {
        texts.removeAll()
    }
}

/// The shared cache for the app's cells, emptied when the locale or the
/// time zone changes.
@MainActor
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationShortTime {
    private static var cache = ConversationShortTimeCache()
    private static var observers: [any NSObjectProtocol] = []

    /// `date`'s short time, as `date.formatted(date: .omitted, time: .shortened)`.
    public static func text(for date: Date) -> String {
        if observers.isEmpty { observe() }
        return cache.text(for: date)
    }

    private static func observe() {
        let center = NotificationCenter.default
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cache.removeAll() }
            })
        }
    }
}
