public import CmuxNextBrowser
import Foundation

/// Typed reads of a driver call's params. A missing required field or a field
/// of the wrong type is an `invalid` error that names the method and field.
public nonisolated struct DriverParams: Sendable {
    public let method: String
    private let fields: [String: DriverJSON]

    public init(method: String, json: DriverJSON) throws(DriverError) {
        self.method = method
        switch json {
        case .object(let fields): self.fields = fields
        case .null: self.fields = [:]
        default: throw DriverError(.invalid, "\(method): params must be an object")
        }
    }

    public func has(_ key: String) -> Bool {
        if case .null = fields[key] ?? .null { return false }
        return true
    }

    public subscript(_ key: String) -> DriverJSON? {
        if case .null = fields[key] ?? .null { return nil }
        return fields[key]
    }

    public func string(_ key: String) throws(DriverError) -> String {
        guard let value = try optionalString(key) else { throw missing(key, "a string") }
        return value
    }

    public func optionalString(_ key: String) throws(DriverError) -> String? {
        guard let value = self[key] else { return nil }
        guard case .string(let string) = value else { throw wrong(key, "a string") }
        return string
    }

    public func number(_ key: String) throws(DriverError) -> Double {
        guard let value = try optionalNumber(key) else { throw missing(key, "a number") }
        return value
    }

    public func optionalNumber(_ key: String) throws(DriverError) -> Double? {
        guard let value = self[key] else { return nil }
        guard case .number(let number) = value, number.isFinite else { throw wrong(key, "a finite number") }
        return number
    }

    public func bool(_ key: String, default fallback: Bool = false) throws(DriverError) -> Bool {
        guard let value = self[key] else { return fallback }
        guard case .bool(let flag) = value else { throw wrong(key, "a boolean") }
        return flag
    }

    public func strings(_ key: String) throws(DriverError) -> [String] {
        guard let value = self[key] else { return [] }
        guard case .array(let items) = value else { throw wrong(key, "an array of strings") }
        var out: [String] = []
        for item in items {
            guard case .string(let string) = item else { throw wrong(key, "an array of strings") }
            out.append(string)
        }
        return out
    }

    public func array(_ key: String) throws(DriverError) -> [DriverJSON] {
        guard let value = self[key] else { return [] }
        guard case .array(let items) = value else { throw wrong(key, "an array") }
        return items
    }

    /// The call's deadline: `fallback` when absent, nil (none) for 0, as
    /// Playwright's `timeout: 0`.
    public func timeout(default fallback: Duration = .seconds(30)) throws(DriverError) -> Duration? {
        guard let ms = try optionalNumber("timeoutMs") else { return fallback }
        guard ms > 0 else { return nil }
        return .milliseconds(Int64(ms.rounded()))
    }

    private func missing(_ key: String, _ type: String) -> DriverError {
        DriverError(.invalid, "\(method): \(key): expected \(type)")
    }

    private func wrong(_ key: String, _ type: String) -> DriverError {
        DriverError(.invalid, "\(method): \(key): expected \(type), got \(Self.describe(fields[key] ?? .null))")
    }

    private static func describe(_ value: DriverJSON) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}
