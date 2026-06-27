import Foundation

extension BrowserAutomationController {
    // MARK: - Params (byte-faithful leaf parsers, worker-lane local)

    /// The boolean param at `key` (mirrors the app's `v2Bool`: `Bool`, boxed
    /// `NSNumber`, or the `1/true/yes/on` / `0/false/no/off` string forms).
    nonisolated static func boolParam(_ params: [String: Any], _ key: String) -> Bool? {
        if let b = params[key] as? Bool { return b }
        if let n = params[key] as? NSNumber { return n.boolValue }
        if let s = params[key] as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    /// The integer param at `key` (mirrors the app's `v2Int`: `Int`, boxed
    /// `NSNumber`, or a parseable string).
    nonisolated static func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    /// The trimmed non-empty string param at `key` (mirrors the app's `v2String`).
    nonisolated static func stringParam(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `value` or `NSNull()` when `nil` (mirrors the app's `v2OrNull`, avoiding the
    /// `?? NSNull()` inference some toolchains disagree on).
    nonisolated static func orNull(_ value: Any?) -> Any {
        if let value { return value }
        return NSNull()
    }
}
