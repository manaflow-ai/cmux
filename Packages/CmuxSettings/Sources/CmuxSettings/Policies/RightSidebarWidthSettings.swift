import Foundation

public enum RightSidebarWidthSettings {
    public static let jsonKey = "rightMaxWidth"
    public static let settingsPath = "sidebar.rightMaxWidth"
    public static let maxWidthKey = "rightSidebarMaxWidth"
    public static let noOverrideValue = -1.0
    public static let minimumWidth = 276.0
    public static let defaultConfiguredMaximumWidth = 900.0
    public static let settingsEditorMaximumWidth = 4096.0

    public static func configuredMaximumWidth(from storedValue: Double) -> Double? {
        guard storedValue.isFinite, storedValue > 0 else {
            return nil
        }
        return storedValue
    }

    public static func clampedSettingsEditorMaximumWidth(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultConfiguredMaximumWidth
        }
        return min(settingsEditorMaximumWidth, max(minimumWidth, value.rounded()))
    }
}
