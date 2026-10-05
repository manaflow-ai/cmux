import SwiftUI

/// Colors for the selected tile in Settings pickers (theme, app icon,
/// terminal theme). The Settings root owns the value and injects it through
/// `\.settingsSelectionStyle`; the defaults are the neutral gray Settings
/// uses so selection chrome never takes the accent color, which stays for
/// control values such as switches.
struct SettingsSelectionStyle: Equatable {
    /// Fill behind a selected tile.
    var selectedFill = Color.primary.opacity(0.10)
    /// Outline of a selected tile.
    var selectedStroke = Color.primary.opacity(0.45)
}

private struct SettingsSelectionStyleKey: EnvironmentKey {
    static let defaultValue = SettingsSelectionStyle()
}

extension EnvironmentValues {
    /// Selection colors for Settings picker tiles, injected by the Settings root.
    var settingsSelectionStyle: SettingsSelectionStyle {
        get { self[SettingsSelectionStyleKey.self] }
        set { self[SettingsSelectionStyleKey.self] = newValue }
    }
}
