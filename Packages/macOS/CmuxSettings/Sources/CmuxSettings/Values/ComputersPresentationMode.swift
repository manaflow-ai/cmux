import Foundation

/// How paired remote computers are presented in the app.
///
/// Stored under the catalog entry ``ComputersCatalogSection/presentation``
/// (`computers.presentation` in `~/.config/cmux/cmux.json`). The raw values
/// are the on-disk strings, so they must not be renamed without a migration.
public enum ComputersPresentationMode: String, CaseIterable, Sendable, SettingCodable {
    /// Each remote computer opens in its own auxiliary viewer window
    /// (the default): one window per computer, opened from Settings ›
    /// Computers or the sidebar scope picker.
    case windows

    /// Remote computers merge into the main window: the sidebar scope picker
    /// (bottom of the workspace sidebar) switches between This Mac, a
    /// specific computer, or all computers — mirroring the iOS app's
    /// workspace-title Mac picker.
    case sidebar
}
