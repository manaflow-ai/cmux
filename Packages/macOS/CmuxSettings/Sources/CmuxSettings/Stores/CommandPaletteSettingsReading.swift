import Foundation

/// Read access to the command-palette behavior settings.
///
/// Consumer domains (the palette views, the rename flow, socket debug
/// commands) depend on this seam instead of the concrete
/// ``CommandPaletteSettingsStore``.
public protocol CommandPaletteSettingsReading: Sendable {
    /// Whether focusing the palette's rename field selects the existing name.
    var renameSelectsAllOnFocus: Bool { get }

    /// Whether the palette's switcher search matches all surfaces instead of
    /// only workspace names.
    var switcherSearchesAllSurfaces: Bool { get }
}
