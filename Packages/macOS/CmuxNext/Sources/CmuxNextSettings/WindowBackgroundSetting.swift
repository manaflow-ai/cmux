public import CmuxNextDesign

/// `appearance.backgroundOpacity` (0...1) and `appearance.backgroundBlur`
/// (`frosted`, `glass`, `glass-clear` or `none` for no blur) in cmux.json: cmux's own
/// window background over Ghostty's `background-opacity` and
/// `background-blur`. Unset keys keep Ghostty's values, so a window stays
/// opaque until one of the two configs asks for translucency.
public nonisolated enum WindowBackgroundSetting {
    /// `appearance.backgroundOpacity`: the window's opacity, 0...1.
    public static let opacityPath = ["appearance", "backgroundOpacity"]
    /// `appearance.backgroundBlur`: the window material (`frosted`,
    /// `glass`, `glass-clear`, or `none` for no blur).
    public static let materialPath = ["appearance", "backgroundBlur"]
    /// The opacity range, as Ghostty's `background-opacity`.
    public static let opacityRange: ClosedRange<Double> = 0...1
    /// `appearance.inactiveWindowDim`: how much more of the theme color covers a window that is
    /// not key, 0...1. 0 (the default): a window looks the same in front and behind.
    public static let inactiveDimPath = ["appearance", "inactiveWindowDim"]
    public static let inactiveDimRange: ClosedRange<Double> = 0...1

    /// The other window background key a write to `path` changes with it,
    /// so the pair is either Ghostty's or cmux's own: an opacity with
    /// Material unset (Ghostty) also names the material Ghostty's blur gives.
    /// Removing the opacity removes that material too (back to Ghostty), but
    /// keeps one the user chose; removing the material removes the opacity.
    ///
    /// - Parameter path: The key being written.
    /// - Parameter value: Its new value; nil removes it.
    /// - Parameter root: The settings document before the write.
    /// - Parameter ghosttyMaterial: The material the config files' own
    ///   `background-blur` gives: what leaving Ghostty names.
    /// - Returns: Extra edits for the same write; empty for any other key.
    public static func linkedEdits(writing path: [String], value: JSONValue?, in root: JSONValue,
                                   ghosttyMaterial: WindowMaterialChoice) -> [(path: [String], value: JSONValue?)] {
        switch path {
        case opacityPath where value != nil:
            guard root.value(at: materialPath) == nil else { return [] }
            return [(materialPath, .string(ghosttyMaterial.rawValue))]
        case opacityPath:
            return root.value(at: materialPath)?.stringValue == ghosttyMaterial.rawValue ? [(materialPath, nil)] : []
        case materialPath where value == nil:
            return root.value(at: opacityPath) == nil ? [] : [(opacityPath, nil)]
        default:
            return []
        }
    }

    /// A missing key keeps Ghostty's value with no diagnostic; a bad value
    /// keeps it too, plus a diagnostic at the key.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WindowBackgroundOverride {
        var opacity: Double?
        if let value = root.value(at: opacityPath) {
            if let number = value.doubleValue, opacityRange.contains(number) {
                opacity = number
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundOpacity",
                                                      message: "expected a number from 0 to 1, such as 0.85"))
            }
        }
        var material: WindowMaterialChoice?
        if let value = root.value(at: materialPath) {
            if let text = value.stringValue, let choice = WindowMaterialChoice(rawValue: text) {
                material = choice
            } else {
                let choices = WindowMaterialChoice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundBlur",
                                                      message: "expected one of \(choices)"))
            }
        }
        return WindowBackgroundOverride(opacity: opacity, material: material)
    }

    /// `appearance.inactiveWindowDim`; a missing key is 0, a bad value 0 plus a diagnostic.
    static func parseInactiveDim(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: inactiveDimPath) else { return 0 }
        guard let number = value.doubleValue, inactiveDimRange.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.inactiveWindowDim",
                                                  message: "expected a number from 0 to 1, such as 0.15"))
            return 0
        }
        return number
    }
}
