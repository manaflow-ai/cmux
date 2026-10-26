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

    /// Seconds since 1970 as a date; nil outside ``keptSeconds`` (and for NaN). `clampingFuture`
    /// (cookie expiries) keeps a later time as the last kept second, so the cookie stays persistent;
    /// Chromium shortens every expiry to 400 days anyway (CanonicalCookie::ValidateAndAdjustExpiryDate).
    public func unix(_ seconds: Double, clampingFuture: Bool = false) -> Date? {
        if clampingFuture, seconds > Self.keptSeconds.upperBound { return Self.lastKept }
        guard Self.keptSeconds.contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Chromium: microseconds since 1601-01-01 UTC. Zero means unknown.
    public func chromium(_ microseconds: Int64, clampingFuture: Bool = false) -> Date? {
        guard microseconds > 0 else { return nil }
        return unix(Double(microseconds) / 1_000_000 - chromiumEpochOffset, clampingFuture: clampingFuture)
    }

    /// Firefox: microseconds since 1970-01-01 UTC. Zero means unknown.
    public func mozilla(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return unix(Double(microseconds) / 1_000_000)
    }

    /// Safari: seconds since 2001-01-01 UTC (Core Foundation absolute time).
    public func cocoa(_ seconds: Double, clampingFuture: Bool = false) -> Date? {
        guard seconds > 0 else { return nil }
        let unixSeconds = seconds + Date.timeIntervalBetween1970AndReferenceDate
        if clampingFuture, unixSeconds > Self.keptSeconds.upperBound { return Self.lastKept }
        guard Self.keptSeconds.contains(unixSeconds) else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
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
