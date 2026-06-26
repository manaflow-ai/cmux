internal import Foundation

/// The byte-faithful `JSONValue` coercions for the `workspace.remote.configure`
/// command path (the former app-side `jvBool` / `jvStrictInt` / `jvExpiresAtUnix`).
///
/// These intentionally differ from the general `bool` / `strictInt` twins (the
/// `v2Bool` / `v2StrictInt` lineage) because the configure command historically
/// parsed its numeric and boolean params through `NSNumber`, and the lift must
/// reproduce that exact coercion (including its `CFNumber` edge behavior) rather
/// than the `!= 0` / direct-`Int` shapes the v2 helpers use. They match different
/// legacy helpers and must not be merged.
///
/// The string / array / presence coercions the configure command shares verbatim
/// with the v2 path are reused directly through ``string(_:_:)``,
/// ``rawString(_:_:)``, ``stringArray(_:_:)`` and ``hasNonNull(_:_:)`` — only the
/// three readers that genuinely differ live here.
extension ControlCommandCoordinator {
    /// `workspace.remote.configure`'s boolean coercion: a JSON bool, else the
    /// `NSNumber.boolValue` of a JSON number (matching the legacy
    /// `(params[key] as? NSNumber)?.boolValue` path, including its `CFNumber`
    /// char-truncation — e.g. `256` and `0.5` both coerce to `false`), else the
    /// `1`/`true`/`yes`/`on` / `0`/`false`/`no`/`off` string set; otherwise `nil`.
    ///
    /// Distinct from ``bool(_:_:)``, which treats any nonzero number as `true`.
    public func remoteConfigureBool(_ params: [String: JSONValue], _ key: String) -> Bool? {
        switch params[key] {
        case .bool(let value):
            return value
        case .int(let value):
            return NSNumber(value: value).boolValue
        case .double(let value):
            return NSNumber(value: value).boolValue
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        case .null, .array, .object, .none:
            return nil
        }
    }

    /// `workspace.remote.configure`'s strict-integer coercion: a non-boolean
    /// integral number — routed through `Double` exactly as the legacy
    /// `v2StrictIntAny` did on the single `NSNumber`, so a `.int` beyond `Double`'s
    /// exact range rounds (or overflows to `nil`) identically — or a parsable
    /// integer string; fractional or non-finite numbers and booleans are rejected.
    ///
    /// Distinct from ``strictInt(_:_:)``, which returns a `.int` directly without
    /// the `Double` round-trip.
    public func remoteConfigureStrictInt(_ params: [String: JSONValue], _ key: String) -> Int? {
        switch params[key] {
        case .bool:
            return nil
        case .int(let value):
            let doubleValue = Double(value)
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else { return nil }
            return Int(exactly: doubleValue)
        case .double(let doubleValue):
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else { return nil }
            return Int(exactly: doubleValue)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .null, .array, .object, .none:
            return nil
        }
    }

    /// `workspace.remote.configure`'s daemon-WebSocket expiry coercion: a JSON int
    /// verbatim, a JSON double truncated via `Int64(exactly:) ?? Int64(_:)`
    /// (preserving the legacy `(as? Int64) ?? Int64((as? Double) ?? 0)` truncation
    /// and its overflow/NaN trap), a JSON bool as `1`/`0`, otherwise `0`.
    public func remoteConfigureExpiresAtUnix(_ params: [String: JSONValue], _ key: String) -> Int64 {
        switch params[key] {
        case .int(let value):
            return value
        case .double(let value):
            return Int64(exactly: value) ?? Int64(value)
        case .bool(let value):
            return value ? 1 : 0
        case .string, .null, .array, .object, .none:
            return 0
        }
    }
}
