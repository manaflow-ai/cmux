public import CmuxNextDesign
import CoreGraphics

/// Reads typed fields of one cmux.json object and records a diagnostic for
/// every bad value, which then keeps its default.
struct ConfigFieldReader {
    let members: [String: JSONValue]
    let path: String
    var diagnostics: [SettingsDiagnostic] = []

    /// The object at `keyPath`, or nil (with a diagnostic when it is not an object).
    init?(_ root: JSONValue, at keyPath: [String], diagnostics: inout [SettingsDiagnostic]) {
        guard let value = root.value(at: keyPath) else { return nil }
        let path = keyPath.joined(separator: ".")
        guard case .object(let members) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object"))
            return nil
        }
        self.members = members
        self.path = path
    }

    private mutating func fail(_ key: String, _ message: String) {
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(key)", message: message))
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let value = members[key] else { return nil }
        guard let bool = value.boolValue else { fail(key, "expected true or false"); return nil }
        return bool
    }

    mutating func number(_ key: String, range: ClosedRange<Double>) -> Double? {
        guard let value = members[key] else { return nil }
        guard let number = value.doubleValue, number.isFinite else { fail(key, "expected a number"); return nil }
        if !range.contains(number) { fail(key, "clamped to \(range.lowerBound)...\(range.upperBound)") }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    mutating func points(_ key: String, range: ClosedRange<CGFloat>) -> CGFloat? {
        number(key, range: Double(range.lowerBound)...Double(range.upperBound)).map { CGFloat($0) }
    }

    /// A choice from `T`'s raw values.
    mutating func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
        guard let value = members[key] else { return nil }
        guard let text = value.stringValue, let choice = T(rawValue: text) else {
            fail(key, "expected one of \(T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))")
            return nil
        }
        return choice
    }

    /// A `#RRGGBB` color; `null` or `"theme"` mean the theme default (`.some(nil)`).
    mutating func color(_ key: String) -> ThemeRGB?? {
        guard let value = members[key] else { return nil }
        if case .null = value { return .some(nil) }
        guard let text = value.stringValue else { fail(key, "expected a #RRGGBB color"); return nil }
        if text == "theme" { return .some(nil) }
        guard let color = ThemeRGB(cssHex: text) else { fail(key, "expected a #RRGGBB color"); return nil }
        return .some(color)
    }

    mutating func string(_ key: String) -> String? {
        guard let value = members[key] else { return nil }
        guard let text = value.stringValue else { fail(key, "expected a string"); return nil }
        return text
    }
}
