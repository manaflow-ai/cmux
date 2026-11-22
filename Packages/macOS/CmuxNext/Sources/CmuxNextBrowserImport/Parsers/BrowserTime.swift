public import Foundation

/// Timestamp encodings used by browser databases.
public struct BrowserTime {
    /// Creates a converter for browser database timestamps.
    public init() {}

    /// Seconds between 1601-01-01 (Windows FILETIME epoch, Chromium) and 1970-01-01.
    let chromiumEpochOffset: Double = 11_644_473_600

    /// Chromium: microseconds since 1601-01-01 UTC. Zero means unknown.
    public func chromium(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - chromiumEpochOffset)
    }

    public func chromiumMicroseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + chromiumEpochOffset) * 1_000_000)
    }

    /// Firefox: microseconds since 1970-01-01 UTC. Zero means unknown.
    public func mozilla(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    /// Safari: seconds since 2001-01-01 UTC (Core Foundation absolute time).
    public func cocoa(_ seconds: Double) -> Date? {
        guard seconds > 0 else { return nil }
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
