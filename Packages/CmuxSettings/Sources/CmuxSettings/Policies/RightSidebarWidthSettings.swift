import Foundation

public enum RightSidebarWidthSettings {
    public static let jsonKey = "rightMaxWidth"
    public static let settingsPath = "sidebar.rightMaxWidth"
    public static let maxWidthKey = "rightSidebarMaxWidth"
    public static let rememberedMaxWidthKey = "rightSidebarRememberedMaxWidth"
    public static let noOverrideValue = -1.0
    public static let minimumWidth = 276.0
    public static let defaultConfiguredMaximumWidth = 900.0
    public static let settingsEditorMaximumWidth = 4096.0

    public static func configuredMaximumWidth(from storedValue: Double) -> Double? {
        guard storedValue.isFinite, storedValue > 0 else {
            return nil
        }
        return clampedSettingsEditorMaximumWidth(storedValue)
    }

    public static func clampedSettingsEditorMaximumWidth(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultConfiguredMaximumWidth
        }
        return min(settingsEditorMaximumWidth, max(minimumWidth, value.rounded()))
    }

    public static func rememberedMaximumWidth(from storedValue: Double) -> Double {
        guard let configuredMaximumWidth = configuredMaximumWidth(from: storedValue) else {
            return defaultConfiguredMaximumWidth
        }
        return clampedSettingsEditorMaximumWidth(configuredMaximumWidth)
    }

    public static func editorMaximumWidth(activeStoredValue: Double, rememberedStoredValue: Double) -> Double {
        if let configuredMaximumWidth = configuredMaximumWidth(from: activeStoredValue) {
            return clampedSettingsEditorMaximumWidth(configuredMaximumWidth)
        }
        return rememberedMaximumWidth(from: rememberedStoredValue)
    }

    public static func storedMaximumWidthWhenEnabling(rememberedStoredValue: Double) -> Double {
        rememberedMaximumWidth(from: rememberedStoredValue)
    }

    public static func storedRememberedMaximumWidth(activeStoredValue: Double, rememberedStoredValue: Double) -> Double {
        editorMaximumWidth(activeStoredValue: activeStoredValue, rememberedStoredValue: rememberedStoredValue)
    }
}
