import Foundation

/// A `Sendable`, value-typed JSON value used as the wire currency of the
/// settings control layer.
///
/// The catalog stores values through ``SettingCodable``, whose
/// `encodeForJSON()` / `decodeFromJSON(_:)` speak loose `Any` (the
/// `JSONSerialization` representation). `Any` is not `Sendable` and cannot
/// cross actor boundaries, so the control engine converts every value into a
/// `SettingJSONValue` for reads and accepts one for writes. It also gives the
/// engine a single, dependency-free, canonical text serializer with stable
/// (sorted-key) output for `--json` and export.
public enum SettingJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([SettingJSONValue])
    indirect case object([String: SettingJSONValue])

    /// Builds a value from a `JSONSerialization` / `SettingCodable.encodeForJSON()`
    /// representation. Distinguishes `Bool` from numeric `NSNumber` via the
    /// CoreFoundation boolean type id (the same guard the scalar
    /// ``SettingCodable`` conformances use), so `true` never collapses to `1`.
    public init(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as SettingJSONValue:
            self = value
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let double = number.doubleValue
                if double.rounded() == double,
                   double >= Double(Int.min), double <= Double(Int.max) {
                    self = .int(number.intValue)
                } else {
                    self = .double(double)
                }
            }
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { SettingJSONValue(jsonObject: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { SettingJSONValue(jsonObject: $0) })
        default:
            self = .null
        }
    }

    /// The `JSONSerialization` / `SettingCodable.decodeFromJSON(_:)` input form.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(\.jsonObject)
        case let .object(values): return values.mapValues(\.jsonObject)
        }
    }

    /// Parses a raw command-line argument as JSON, falling back to a bare
    /// string when it is not valid JSON (so `dark` becomes `.string("dark")`
    /// while `true`, `42`, `["a"]`, `{…}` parse structurally). Used only for
    /// value types whose CLI input is JSON-shaped; scalar/enum/string inputs are
    /// parsed type-directed by the engine.
    public static func parseJSON(_ raw: String) -> SettingJSONValue {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return .string(raw)
        }
        return SettingJSONValue(jsonObject: object)
    }

    /// A stable, canonical JSON text rendering (objects sorted by key), used for
    /// `--json` output and export. Self-contained so output is identical across
    /// platforms and never depends on `NSNumber` boxing quirks.
    public var jsonText: String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .string(value):
            return Self.encodeString(value)
        case let .array(values):
            return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
        case let .object(values):
            let body = values.keys.sorted().map { key in
                Self.encodeString(key) + ":" + values[key]!.jsonText
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }

    /// A human-facing rendering for non-`--json` output: scalars print bare
    /// (no surrounding quotes), structured values print as compact JSON.
    public var displayString: String {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .string(value): return value
        case .array, .object: return jsonText
        }
    }

    private static func encodeString(_ value: String) -> String {
        // Escape per RFC 8259 so the canonical text is valid JSON.
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case let s where s.value < 0x20:
                result += String(format: "\\u%04x", s.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
