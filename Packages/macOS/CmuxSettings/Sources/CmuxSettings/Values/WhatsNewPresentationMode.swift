import Foundation

/// How much cmux says about a new version after an update (`app.whatsNew`).
///
/// Ordered from least to most intrusive. Every mode keeps the on-demand
/// entrypoints (Help menu, command palette, sidebar help menu); the mode only
/// controls what happens on its own after the first launch of a new version.
public enum WhatsNewPresentationMode: String, CaseIterable, Sendable, SettingCodable {
    /// Nothing automatic.
    case off
    /// A small indicator on the sidebar help button until the recap is opened.
    case quiet
    /// Open the recap once, as a sheet, after the first launch of a new version.
    case sheet
}
