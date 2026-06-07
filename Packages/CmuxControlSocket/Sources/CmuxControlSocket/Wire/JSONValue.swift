internal import Foundation

/// A fully typed, `Sendable` JSON value used by the control-socket wire DTOs.
///
/// Replaces the `Any`-shaped payloads (`JSONSerialization` output) that the v2
/// protocol historically carried, so requests and results can cross isolation
/// boundaries as plain values. Bridging to and from Foundation objects is
/// lossless for everything `JSONSerialization` produces, with one documented
/// exception: integers that do not fit `Int64` (and decimal literals beyond
/// `Double` precision) are bridged as `Double` and may lose precision.
public enum JSONValue: Sendable, Equatable {
    /// JSON `null`.
    case null
    /// JSON `true` / `false`.
    case bool(Bool)
    /// A JSON number that is an exact integer representable in `Int64`.
    case int(Int64)
    /// Any other JSON number.
    case double(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])

    /// Bridges a Foundation JSON object (the shapes produced by
    /// `JSONSerialization` or by hand-built `[String: Any]` payloads) into a
    /// typed value.
    ///
    /// Booleans are distinguished from numbers via `CFBoolean` type identity,
    /// matching how `JSONSerialization` represents them. Returns `nil` when the
    /// object contains anything that is not valid JSON (mirroring the legacy
    /// `JSONSerialization.isValidJSONObject` encode-failure path).
    ///
    /// - Parameter foundationObject: The Foundation representation to bridge.
    public init?(foundationObject: Any) {
        switch foundationObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let exact = JSONValue.exactInt64(from: number) {
                self = .int(exact)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    /// The Foundation representation of this value, in the shapes
    /// `JSONSerialization` accepts (`NSNull`, `NSNumber`, `String`, `[Any]`,
    /// `[String: Any]`).
    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return NSNumber(value: value)
        case .int(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let values):
            return values.mapValues(\.foundationObject)
        }
    }

    /// Returns the number as `Int64` only when it is stored as an integer type
    /// and fits exactly. Floating-point numbers stay floating-point even when
    /// integral, preserving the legacy `NSNumber` round-trip semantics.
    private static func exactInt64(from number: NSNumber) -> Int64? {
        switch UnicodeScalar(UInt8(number.objCType.pointee)) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q":
            return number.int64Value
        case "Q":
            let unsigned = number.uint64Value
            guard unsigned <= UInt64(Int64.max) else { return nil }
            return Int64(unsigned)
        default:
            return nil
        }
    }
}
