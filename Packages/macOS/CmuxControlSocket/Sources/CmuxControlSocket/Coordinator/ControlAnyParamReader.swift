public import Foundation

/// The `[String: Any]`-lane param decoders, lifted out of the former
/// `TerminalControllerV2ParamParsingSupport` app-target helpers.
///
/// These are the byte-faithful twins of the typed
/// ``ControlCommandCoordinator`` `[String: JSONValue]` helpers
/// (see `ControlCommandCoordinator+Params.swift`), but operate on the
/// untyped `[String: Any]` dictionaries the app-side v2 dispatch still
/// hands in. Each method mirrors its legacy counterpart's acceptance rules
/// exactly (NSNumber coercion, trimming, normalization) so the moved
/// command bodies parse identically.
///
/// This is a real value type with INSTANCE methods, deliberately not a
/// static-only namespace: callers hold an instance and read params through
/// it. The methods are pure value transforms over `[String: Any]` returning
/// Foundation values, calling only each other, with zero reach into app
/// state.
///
/// The app-coupled members of the legacy support file are NOT here and stay
/// app-side: `v2UUID`/`v2UUIDAny` (ref resolution through the coordinator),
/// `v2LocatePane` (`AppDelegate` walk), `v2PanelType` (returns a Bonsplit
/// `PanelType` this package does not depend on), and
/// `v2InitialDividerPosition` (returns an app-side `V2CallResult`).
public struct ControlAnyParamReader: Sendable {
    /// Creates a reader. Stateless: the decoders are pure transforms.
    public init() {}

    /// `v2String`: a trimmed non-empty string, or `nil`.
    public func string(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `v2StringArray`: a string array (trimmed, empties dropped); a JSON
    /// array of mixed values keeps only its trimmed non-empty strings; a
    /// single trimmed non-empty string yields a one-element array;
    /// otherwise `nil`.
    public func stringArray(_ params: [String: Any], _ key: String) -> [String]? {
        if let raw = params[key] as? [String] {
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let raw = params[key] as? [Any] {
            let normalized = raw
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized
        }
        if let single = string(params, key) {
            return [single]
        }
        return nil
    }

    /// `v2StringMap`: a `[String: String]` directly, or the string-valued
    /// entries of a `[String: Any]` object; otherwise `nil`.
    public func stringMap(_ params: [String: Any], _ key: String) -> [String: String]? {
        guard let raw = params[key] else { return nil }
        if let dict = raw as? [String: String] {
            return dict
        }
        if let anyDict = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, value) in anyDict {
                guard let stringValue = value as? String else { continue }
                out[k] = stringValue
            }
            return out
        }
        return nil
    }

    /// `v2TrimmedStringMap`: the first present string-map among `keys`, with
    /// trimmed non-empty keys; `[:]` when none present.
    public func trimmedStringMap(_ params: [String: Any], keys: [String]) -> [String: String] {
        for key in keys {
            guard let raw = stringMap(params, key) else { continue }
            return raw.reduce(into: [String: String]()) { result, pair in
                let normalizedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty else { return }
                result[normalizedKey] = pair.value
            }
        }
        return [:]
    }

    /// `v2ActionKey`: a trimmed string lowercased with `-` mapped to `_`.
    public func actionKey(_ params: [String: Any], _ key: String = "action") -> String? {
        guard let action = string(params, key) else { return nil }
        return action.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    /// `v2RawString`: the raw string value, untrimmed, or `nil`.
    public func rawString(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    /// `v2OptionalTrimmedRawString`: trimmed raw string, `nil` when empty.
    public func optionalTrimmedRawString(_ params: [String: Any], _ key: String) -> String? {
        let trimmed = rawString(params, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// `v2Bool`: a `Bool`, an `NSNumber` (`.boolValue`), or the
    /// `1/true/yes/on` / `0/false/no/off` string set; otherwise `nil`.
    public func bool(_ params: [String: Any], _ key: String) -> Bool? {
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

    /// `v2Int`: an `Int`, an `NSNumber` (`.intValue`), or a parsable string.
    public func int(_ params: [String: Any], _ key: String) -> Int? {
        if let i = params[key] as? Int { return i }
        if let n = params[key] as? NSNumber { return n.intValue }
        if let s = params[key] as? String { return Int(s) }
        return nil
    }

    /// `v2Double`: a `Double`, `Float`, `NSNumber` (`.doubleValue`), or a
    /// parsable string.
    public func double(_ params: [String: Any], _ key: String) -> Double? {
        if let d = params[key] as? Double { return d }
        if let f = params[key] as? Float { return Double(f) }
        if let n = params[key] as? NSNumber { return n.doubleValue }
        if let s = params[key] as? String { return Double(s) }
        return nil
    }

    /// `v2HasNonNullParam`: the key is present and not `NSNull`.
    public func hasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        guard let raw = params[key] else { return false }
        return !(raw is NSNull)
    }

    /// `v2StrictInt`: an exact integer only — a non-boolean integral number
    /// or a parsable integer string; fractional or non-finite numbers are
    /// rejected.
    public func strictInt(_ params: [String: Any], _ key: String) -> Int? {
        strictIntAny(params[key])
    }

    /// `v2StrictIntAny`: the strict-int rule for a single `Any?` value. A
    /// JSON boolean (which bridges to an `NSNumber` whose type id is
    /// `CFBooleanGetTypeID`) is rejected; an integral finite number or a
    /// parsable integer string is accepted.
    public func strictIntAny(_ raw: Any?) -> Int? {
        guard let raw else { return nil }

        if let numberValue = raw as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = numberValue.doubleValue
            guard doubleValue.isFinite, floor(doubleValue) == doubleValue else {
                return nil
            }
            return Int(exactly: doubleValue)
        }

        if let intValue = raw as? Int {
            return intValue
        }

        if let stringValue = raw as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    /// `v2NormalizedToken`: lowercased with `-`, `_`, and spaces stripped.
    public func normalizedToken(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
