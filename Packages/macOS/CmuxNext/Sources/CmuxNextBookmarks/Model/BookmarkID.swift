public import Foundation

/// Bookmark ids: `bm_` and 32 lowercase hex digits, minted by the writer.
public nonisolated enum BookmarkID {
    public static func make() -> String {
        "bm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func isValid(_ id: String) -> Bool {
        guard id.hasPrefix("bm_"), id.count == 35 else { return false }
        return id.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Milliseconds since 1970, the wire and file representation of times.
public nonisolated enum BookmarkTime {
    public static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
