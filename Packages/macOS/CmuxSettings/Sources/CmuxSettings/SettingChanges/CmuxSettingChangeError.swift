import CmuxFoundation
import Foundation

/// A ``CmuxSettingChange`` refused before anything was written.
public enum CmuxSettingChangeError: LocalizedError, Sendable, Equatable {
    /// The path is empty, has an empty component, or isn't declared by the
    /// cmux.json schema.
    case unknownPath(String)
    /// The path is inside a section that holds hand-written configuration
    /// (`actions`, `commands`, `ui`, ...) rather than settings.
    case notASetting(String)
    /// `toggle` found a value that isn't a boolean.
    case notBoolean(String)
    /// `cycle` was given no values.
    case emptyCycle(String)
    /// `settingPresets.<name>` doesn't exist.
    case unknownPreset(String)
    /// `settingPresets.<name>` isn't an object of settings.
    case invalidPreset(String)

    public var errorDescription: String? {
        let localization = CmuxConfigValidationLocalization()
        switch self {
        case .unknownPath(let path):
            return localization.format(
                "config.settingChange.unknownPath",
                defaultValue: "'%@' isn't a cmux setting. Run `cmux docs settings` to list them.",
                path
            )
        case .notASetting(let path):
            return localization.format(
                "config.settingChange.notASetting",
                defaultValue: "'%@' isn't a setting. Edit that section of cmux.json directly.",
                path
            )
        case .notBoolean(let path):
            return localization.format(
                "config.settingChange.notBoolean",
                defaultValue: "'%@' isn't true or false, so it can't be toggled.",
                path
            )
        case .emptyCycle(let path):
            return localization.format(
                "config.settingChange.emptyCycle",
                defaultValue: "Cycling '%@' needs at least one value.",
                path
            )
        case .unknownPreset(let name):
            return localization.format(
                "config.settingChange.unknownPreset",
                defaultValue: "No setting preset named '%@'. Add it under settingPresets in ~/.config/cmux/cmux.json.",
                name
            )
        case .invalidPreset(let name):
            return localization.format(
                "config.settingChange.invalidPreset",
                defaultValue: "Setting preset '%@' must be an object of settings, for example {\"sidebar\": {\"showPorts\": false}}.",
                name
            )
        }
    }
}
