public import Foundation

/// Timestamp encodings used by browser databases.
public struct BrowserTime {
    /// Creates a converter for browser database timestamps.
    public init() {}

    /// Seconds between 1601-01-01 (Windows FILETIME epoch, Chromium) and 1970-01-01.
    let chromiumEpochOffset: Double = 11_644_473_600

    /// Seconds since 1970 of 0001-01-01 and 9999-12-31 23:59:59 UTC: the dates an import keeps. A
    /// corrupt profile can hold any number; outside this range a time means nothing, and in it every
    /// date fits the Int64 microseconds Chromium's stores and exports convert it to (base::Time).
    static let keptSeconds: ClosedRange<Double> = -62_135_596_800...253_402_300_799

    /// The last kept second, for an expiry past it.
    static let lastKept = Date(timeIntervalSince1970: keptSeconds.upperBound)

    /// Seconds since 1970 as a date; nil outside ``keptSeconds`` (and for NaN).
    public func unix(_ seconds: Double) -> Date? {
        guard Self.keptSeconds.contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A cookie expiry in seconds since 1970: as ``unix(_:)``, but a later time is kept as the last
    /// kept second, so the cookie stays persistent; Chromium shortens every expiry to 400 days anyway
    /// (CanonicalCookie::ValidateAndAdjustExpiryDate).
    public func unixExpiry(_ seconds: Double) -> Date? {
        seconds > Self.keptSeconds.upperBound ? Self.lastKept : unix(seconds)
    }

    /// Chromium: microseconds since 1601-01-01 UTC. Zero means unknown.
    public func chromium(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return unix(Double(microseconds) / 1_000_000 - chromiumEpochOffset)
    }

    /// A Chromium cookie expiry, kept past year 9999 as ``unixExpiry(_:)`` keeps it.
    public func chromiumExpiry(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return unixExpiry(Double(microseconds) / 1_000_000 - chromiumEpochOffset)
    }

    /// Firefox: microseconds since 1970-01-01 UTC. Zero means unknown.
    public func mozilla(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return unix(Double(microseconds) / 1_000_000)
    }

    /// Safari: seconds since 2001-01-01 UTC (Core Foundation absolute time).
    public func cocoa(_ seconds: Double) -> Date? {
        guard seconds > 0, Self.keptSeconds.contains(seconds + Date.timeIntervalBetween1970AndReferenceDate) else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A Safari cookie expiry, kept past year 9999 as ``unixExpiry(_:)`` keeps it.
    public func cocoaExpiry(_ seconds: Double) -> Date? {
        guard seconds > 0 else { return nil }
        return seconds + Date.timeIntervalBetween1970AndReferenceDate > Self.keptSeconds.upperBound ? Self.lastKept : cocoa(seconds)
    }

    /// The last kept second in each history store's own unit, for ``sqlKept(_:last:)``.
    static let lastChromium: Int64 = 265_046_774_399_000_000 // (253_402_300_799 + 11_644_473_600) µs since 1601
    static let lastMozilla: Int64 = 253_402_300_799_000_000 // µs since 1970
    static let lastCocoa: Int64 = 252_423_993_599 // s since 2001

    /// SQL that is true when `column` holds a time the import keeps: above zero, not past `last`. Text,
    /// blobs and NULL fail it (SQLite orders them after every number). A history query filters on it
    /// before `ORDER BY … LIMIT`, so corrupt times are counted and never take the limit's places.
    static func sqlKept(_ column: String, last: Int64) -> String {
        "(\(column) > 0 AND \(column) <= \(last))"
    }
}

/// URLs worth importing: web pages and files, never browser-internal pages.
enum ImportableURL {
    /// SQL filter for the same schemes, so `LIMIT` counts only importable rows.
    static func sqlFilter(_ column: String) -> String {
        "(\(column) LIKE 'http:%' OR \(column) LIKE 'https:%' OR \(column) LIKE 'file:%' OR \(column) LIKE 'ftp:%')"
    }

    static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        return ["http", "https", "file", "ftp"].contains(scheme) ? url : nil
    }
}
