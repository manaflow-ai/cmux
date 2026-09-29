import SwiftUI

/// Neutral gray for the selected tile in Settings pickers (theme, app icon,
/// terminal theme). Settings keeps the accent color for control values, such
/// as switches, rather than for selection chrome.
enum SettingsSelectionStyle {
    /// Fill behind a selected tile.
    static let selectedFill = Color.primary.opacity(0.10)
    /// Outline of a selected tile.
    static let selectedStroke = Color.primary.opacity(0.45)
}
