import SwiftUI

/// Neutral gray for selected and focused states in Settings (category rows,
/// the search field focus ring, picker tiles). Settings keeps the accent color
/// for control values, such as switches, rather than for selection chrome.
enum SettingsSelectionStyle {
    /// Fill behind a selected row or tile.
    static let selectedFill = Color.primary.opacity(0.10)
    /// Outline of a selected tile.
    static let selectedStroke = Color.primary.opacity(0.45)
    /// Glyph tint of a selected row.
    static let selectedGlyph = Color.primary
    /// Focus ring of a text field.
    static let focusStroke = Color.primary.opacity(0.35)
}
