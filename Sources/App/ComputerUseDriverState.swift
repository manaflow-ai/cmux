import Foundation

/// A validated snapshot written by the local computer-use driver.
struct ComputerUseDriverState: Equatable, Sendable {
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    let pid: Int
    /// The driver's own session id when one was declared; `null` in the file
    /// for cursor-less runs, and never equal to the cmux hook session id.
    let session: String?
    let targetApp: String
    let targetPID: Int
    let targetWindowID: UInt32
    let lastActionAt: Date

    init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            // The driver writes "driver_pid" (schema 1); accept legacy "pid" too.
            let pid = Self.positiveInt(dictionary["driver_pid"] ?? dictionary["pid"]),
            let targetApp = Self.boundedNonemptyString(dictionary["target_app"], maximumUTF8Bytes: 1_024),
            let targetPID = Self.positiveInt(dictionary["target_pid"]),
            let targetWindowInt = Self.positiveInt(dictionary["target_window_id"]),
            targetWindowInt <= Int(UInt32.max),
            let lastActionAt = Self.date(dictionary["last_action_at"])
        else {
            return nil
        }

        self.pid = pid
        self.session = Self.boundedNonemptyString(dictionary["session"], maximumUTF8Bytes: 1_024)
        self.targetApp = targetApp
        self.targetPID = targetPID
        self.targetWindowID = UInt32(targetWindowInt)
        self.lastActionAt = lastActionAt
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else { return nil }
            parsed = Int(exactly: doubleValue)
        } else if let string = value as? String {
            parsed = Int(string)
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0, parsed <= Int(Int32.max) else { return nil }
        return parsed
    }

    private static func boundedNonemptyString(_ value: Any?, maximumUTF8Bytes: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            return date(timeInterval: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        if let numeric = Double(string) {
            return date(timeInterval: numeric)
        }
        if let parsed = try? fractionalISO8601.parse(string) {
            return parsed
        }
        if let parsed = try? wholeSecondISO8601.parse(string) {
            return parsed
        }
        // The driver writes 6-digit fractional seconds (e.g. ".745752Z"), which
        // ISO8601DateFormatter's fractional mode does not accept on all macOS
        // versions; retry with the fraction truncated to milliseconds.
        if let match = string.range(of: #"\.(\d{3})\d+"#, options: .regularExpression) {
            var truncated = string
            let keep = string[match.lowerBound...].prefix(4)
            truncated.replaceSubrange(match, with: keep)
            return try? fractionalISO8601.parse(truncated)
        }
        return nil
    }

    private static func date(timeInterval: TimeInterval) -> Date? {
        guard timeInterval.isFinite, timeInterval > 0 else { return nil }
        let seconds = timeInterval > 10_000_000_000 ? timeInterval / 1_000 : timeInterval
        return Date(timeIntervalSince1970: seconds)
    }
}
