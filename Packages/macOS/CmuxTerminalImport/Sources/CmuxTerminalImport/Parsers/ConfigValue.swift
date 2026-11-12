import Foundation

/// A scalar or list value read from a TOML, YAML or Lua config, flattened under dotted keys.
enum ConfigValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([ConfigValue])

    var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return Int(exactly: value).map { String($0) } ?? String(value)
        case .bool(let value): return value ? "true" : "false"
        case .list: return nil
        }
    }

    var number: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .string(let value): return Self.decimal(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "on": return true
            case "false", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Parses an unquoted scalar the way YAML and Lua read bare words.
    static func bare(_ text: String) -> ConfigValue {
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            if let number = decimal(text) { return .number(number) }
            return .string(text)
        }
    }

    /// A plain decimal number. `Double(_:)` also accepts hex (`0x1d1f21`), `inf` and `nan`,
    /// which would turn Alacritty's bare hex colors into numbers.
    /// Overflowing input such as `1e999` is rejected rather than read as infinity.
    static func decimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ "0123456789.+-eE".contains($0) }),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// The largest magnitude a config number keeps before it is clamped.
    static let integerLimit = 1_000_000_000_000_000.0

    /// A config number as an `Int`, rounded and clamped so hostile values can't trap.
    ///
    /// - Returns: `nil` for NaN and infinity; otherwise the rounded value, clamped to ±``integerLimit``.
    static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(min(max(value.rounded(), -integerLimit), integerLimit))
    }
}
