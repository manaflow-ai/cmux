public import Foundation

/// Reads weakly-typed values out of a JSON-decoded `[String: Any]` payload,
/// coercing across the `NSNumber`/`Int`/`Int64`/`Double`/`String` shapes that
/// `JSONSerialization` produces for the Task Manager snapshot wire format.
///
/// This is the single owner of the snapshot coercion rules. Before the
/// extraction the same `double`/`int64`/`int`/`intArray`/`string`/`uuid`
/// helpers were duplicated as private statics on both
/// ``CmuxTaskManagerResources`` and ``CmuxTaskManagerMemoryDiagnostic``; the
/// snapshot value models now construct one reader over their payload and ask
/// it for each field, so the coercion behavior lives in exactly one place.
///
/// The reader holds a non-`Sendable` `[String: Any]` payload, so it is a
/// short-lived parse-time value only: callers build it inside a failable/
/// value initializer and discard it. It is never stored on a `Sendable`
/// model nor passed across an isolation boundary.
struct TaskManagerJSONPayloadReader {
    private let payload: [String: Any]

    init(_ payload: [String: Any]) {
        self.payload = payload
    }

    /// A nested object value, as another reader, or `nil` when absent.
    func object(_ key: String) -> TaskManagerJSONPayloadReader? {
        guard let nested = payload[key] as? [String: Any] else { return nil }
        return TaskManagerJSONPayloadReader(nested)
    }

    /// A nested object value as a reader, defaulting to an empty payload.
    func objectOrEmpty(_ key: String) -> TaskManagerJSONPayloadReader {
        TaskManagerJSONPayloadReader(payload[key] as? [String: Any] ?? [:])
    }

    /// A list of nested object payloads, or an empty array when absent.
    func objectArray(_ key: String) -> [[String: Any]] {
        payload[key] as? [[String: Any]] ?? []
    }

    /// A trimmed, non-empty string value, or `nil`.
    func string(_ key: String) -> String? {
        Self.string(payload[key])
    }

    /// A `Double`, defaulting to `0` when absent or uncoercible.
    func double(_ key: String) -> Double {
        let raw = payload[key]
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    /// An `Int64`, defaulting to `0` when absent or uncoercible.
    /// Selects the raw value at `key`, or, only when `key` is absent
    /// (the value is `nil`), the first present `fallbackKey` raw value,
    /// then coerces that single raw value. This matches the legacy
    /// `int64(payload["memory_bytes"] ?? payload["resident_bytes"])`
    /// nil-coalescing on the raw value, so a present-but-uncoercible
    /// `key` resolves to `0` rather than falling through.
    func int64(_ key: String, fallbackKeys: String...) -> Int64 {
        var raw = payload[key]
        if raw == nil {
            for candidate in fallbackKeys {
                if let value = payload[candidate] {
                    raw = value
                    break
                }
            }
        }
        return Self.int64(raw) ?? 0
    }

    /// An `Int`, or `nil` when absent or uncoercible.
    func int(_ key: String) -> Int? {
        Self.int(payload[key])
    }

    /// An array of `Int`s, coercing each element; empty when absent.
    func intArray(_ key: String) -> [Int] {
        let raw = payload[key]
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap(Self.int)
    }

    /// A `UUID` parsed from a `UUID` or a trimmed UUID string, or `nil`.
    func uuid(_ key: String) -> UUID? {
        let raw = payload[key]
        if let value = raw as? UUID { return value }
        guard let value = Self.string(raw) else { return nil }
        return UUID(uuidString: value)
    }

    private static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int64(_ raw: Any?) -> Int64? {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
