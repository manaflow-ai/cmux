public import CmuxNextBrowser
import Foundation

/// Typed reads of a driver call's params. A missing required field or a field
/// of the wrong type is an `invalid` error that names the method and field.
/// The rules (what reads as absent, which type a read takes, the error texts,
/// the deadline's rounding and cap) are Rust's: cmux-browser-rules `driver.rs`,
/// op `browser_rules_automation_driver_params` (``BrowserRulesFFI``).
public nonisolated struct DriverParams: Sendable {
    public let method: String
    private let fields: [String: DriverJSON]
    /// The params as JSON, encoded once for every read.
    private let encoded: Data

    public init(method: String, json: DriverJSON) throws(DriverError) {
        self.method = method
        if case .object(let fields) = json { self.fields = fields } else { self.fields = [:] }
        // A top-level scalar encodes as a JSON fragment; Rust refuses anything but an object or null.
        encoded = (try? JSONSerialization.data(withJSONObject: BrowserRulesFFI.foundation(json), options: [.fragmentsAllowed])) ?? Data("null".utf8)
        _ = try values([])
    }

    public func has(_ key: String) -> Bool {
        (try? value(key, "has")?.boolValue) == true
    }

    public subscript(_ key: String) -> DriverJSON? {
        has(key) ? fields[key] : nil
    }

    public func string(_ key: String) throws(DriverError) -> String {
        try value(key, "string")?.stringValue ?? ""
    }

    public func optionalString(_ key: String) throws(DriverError) -> String? {
        try value(key, "optionalString")?.stringValue
    }

    public func number(_ key: String) throws(DriverError) -> Double {
        try finite(key)
        return try value(key, "number")?.numberValue ?? 0
    }

    public func optionalNumber(_ key: String) throws(DriverError) -> Double? {
        try finite(key)
        return try value(key, "optionalNumber")?.numberValue
    }

    public func bool(_ key: String, default fallback: Bool = false) throws(DriverError) -> Bool {
        try value(key, "bool", default: fallback)?.boolValue ?? fallback
    }

    public func strings(_ key: String) throws(DriverError) -> [String] {
        guard case .array(let items)? = try value(key, "strings") else { return [] }
        return items.compactMap(\.stringValue)
    }

    public func array(_ key: String) throws(DriverError) -> [DriverJSON] {
        _ = try value(key, "array")
        // The items as the caller sent them, not their JSON round trip.
        guard case .array(let items)? = self[key] else { return [] }
        return items
    }

    /// The call's deadline: `fallback` when absent, nil (none) for 0, as
    /// Playwright's `timeout: 0`.
    public func timeout(default fallback: Duration = .seconds(30)) throws(DriverError) -> Duration? {
        try finite("timeoutMs")
        guard let ms = try value("timeoutMs", "timeout", default: Self.milliseconds(fallback))?.numberValue else { return nil }
        return .milliseconds(Int64(ms))
    }

    /// `ms` as a deadline: rounded and capped at a year, which no browser call
    /// outlives (`Int64(_:)` traps on 1e30). Rust's `deadline_ms`.
    static func duration(milliseconds ms: Double) -> Duration {
        CallDeadline.deadline(milliseconds: ms, what: "").duration
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// One read of `key`; nil when Rust answers null (absent).
    private func value(_ key: String, _ read: String, default fallback: Any? = nil) throws(DriverError) -> DriverJSON? {
        var item: [String: Any] = ["key": key, "read": read]
        if let fallback { item["default"] = fallback }
        let value = try values([item]).first ?? .null
        if case .null = value { return nil }
        return value
    }

    /// The reads' answers in order, or the `invalid` error Rust names.
    private func values(_ reads: [[String: Any]]) throws(DriverError) -> [DriverJSON] {
        guard let methodJSON = try? JSONSerialization.data(withJSONObject: method, options: [.fragmentsAllowed]),
              let readsJSON = try? JSONSerialization.data(withJSONObject: reads) else {
            throw DriverError(.invalid, "\(method): params cannot be read")
        }
        var request = Data(#"{"method":"#.utf8)
        request.append(methodJSON)
        request.append(Data(#","params":"#.utf8))
        request.append(encoded)
        request.append(Data(#","reads":"#.utf8))
        request.append(readsJSON)
        request.append(Data("}".utf8))
        guard case .object(let reply)? = BrowserRulesFFI.call("driver_params", data: request) else {
            throw DriverError(.invalid, "\(method): params cannot be read")
        }
        if case .string(let error)? = reply["error"] { throw DriverError(.invalid, error) }
        guard case .array(let values)? = reply["values"] else { throw DriverError(.invalid, "\(method): params cannot be read") }
        return values
    }

    /// JSON has no NaN or infinity, so a non-finite number crosses as 0
    /// (``BrowserRulesFFI/foundation(_:)``); a number read of one fails here
    /// with the error Rust gives a non-finite number.
    private func finite(_ key: String) throws(DriverError) {
        guard case .number(let number)? = fields[key], !number.isFinite else { return }
        throw DriverError(.invalid, "\(method): \(key): expected a finite number, got a number")
    }
}
