import AppKit
import Foundation

/// The dynamic sources the palette can use. Every source is optional; a nil
/// source removes its provider and nested page.
public struct PaletteSources {
    public var workspaces: (any PaletteWorkspaceSource)?
    public var tabs: (any PaletteTabSource)?
    public var openIn: (any PaletteOpenInSource)?
    public var settings: (any PaletteSettingsSource)?
    public var recentDirectories: (any PaletteRecentDirectorySource)?
    /// Extra root providers (custom `cmux.json` actions, extensions).
    public var extraProviders: [any PaletteProvider]

    public init(
        workspaces: (any PaletteWorkspaceSource)? = nil,
        tabs: (any PaletteTabSource)? = nil,
        openIn: (any PaletteOpenInSource)? = nil,
        settings: (any PaletteSettingsSource)? = nil,
        recentDirectories: (any PaletteRecentDirectorySource)? = nil,
        extraProviders: [any PaletteProvider] = []
    ) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.openIn = openIn
        self.settings = settings
        self.recentDirectories = recentDirectories
        self.extraProviders = extraProviders
    }
}

// MARK: - Providers over the sources

/// Shortens a home-relative path to `~/…`.
func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
