import Foundation

/// `terminal.fontFamily` and `terminal.fontSize` in cmux.json: the terminal
/// font, applied as Ghostty overrides on top of the Ghostty config
/// (`GhosttyRuntime.fontOverride`), so every terminal follows live. Absent
/// keys keep the Ghostty config's font.
public struct TerminalFontSetting: Sendable {
    public let familyPath = ["terminal", "fontFamily"]
    public let sizePath = ["terminal", "fontSize"]
    /// Sizes the Ghostty override accepts (`GhosttyRuntime.fontOverrideLines`).
    public let sizeRange: ClosedRange<Double> = 4...96
    /// Longest family name the Ghostty override accepts.
    public let maximumFamilyLength = 120

    public init() {}

    /// Whether `text` is a family name the Ghostty override writes: not
    /// empty, at most `maximumFamilyLength` characters, and none that could
    /// start another config line (control characters, `#`, `=`, `"`).
    public func isValidFamily(_ text: String) -> Bool {
        let family = text.trimmingCharacters(in: .whitespaces)
        return !family.isEmpty && family.count <= maximumFamilyLength
            && family.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !"#=\"".unicodeScalars.contains($0) }
    }

    /// A missing or empty key is the Ghostty config's family with no
    /// diagnostic; a bad value is the same plus a diagnostic.
    func parseFamily(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: familyPath) else { return (nil, nil) }
        let problem = SettingsDiagnostic(kind: .invalidValue, path: "terminal.fontFamily",
                                         message: "expected a font family name of at most \(maximumFamilyLength) characters, without # = or \"")
        guard let text = value.stringValue else { return (nil, problem) }
        let family = text.trimmingCharacters(in: .whitespaces)
        if family.isEmpty { return (nil, nil) }
        guard isValidFamily(family) else { return (nil, problem) }
        return (family, nil)
    }

    /// A missing key is the Ghostty config's size with no diagnostic; a
    /// value that is not a number from 4 to 96 is the same plus a diagnostic.
    func parseSize(_ root: JSONValue) -> (Double?, SettingsDiagnostic?) {
        guard let value = root.value(at: sizePath) else { return (nil, nil) }
        guard let size = value.doubleValue, size.isFinite, sizeRange.contains(size) else {
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "terminal.fontSize",
                                            message: "expected a size in points from \(Int(sizeRange.lowerBound)) to \(Int(sizeRange.upperBound))"))
        }
        return (size, nil)
    }
}
