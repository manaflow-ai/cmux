import Foundation

enum TranscriptTimestampParser {
    static func milliseconds(_ value: JSONValue?) -> Int64? {
        if let number = value?.number {
            let milliseconds = number > 10_000_000_000 ? number : number * 1_000
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                return nil
            }
            return Int64(milliseconds.rounded())
        }
        guard let string = value?.string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date: Date?
        if let fractional = formatter.date(from: string) {
            date = fractional
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: string)
        }
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
