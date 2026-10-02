import AppKit
public import CmuxNextActions
import Foundation

/// The dynamic sources the palette can use. Every source is optional; a nil
/// source removes its provider and nested page.
public struct PaletteSources {
    public var workspaces: (any PaletteWorkspaceSource)?
    public var tabs: (any PaletteTabSource)?
    public var openIn: (any PaletteOpenInSource)?
    public var settings: (any PaletteSettingsSource)?
    public var recentDirectories: (any PaletteRecentDirectorySource)?
    /// Lists objects for target arguments (tab groups, windows, ...).
    public var targets: (any PaletteTargetSource)?
    /// Extra root providers (custom `cmux.json` actions, extensions).
    public var extraProviders: [any PaletteProvider]
    /// The objects the user acts on, captured when the palette opens (the
    /// focused tab, its group, pane, screen, workspace and window). An
    /// action that asks for input runs on these, not on whatever has focus
    /// once the palette closes.
    public var context: (@MainActor () -> [ActionTargetRef])?
    /// Live preview of an enumeration argument page (theme pickers): called
    /// with the highlighted option's value as the selection or hover moves,
    /// and with nil when the page is left without choosing. Choosing runs the
    /// action, which commits; no nil follows it.
    public var argumentPreview: PaletteArgumentPreview?
    /// Actions the palette serves as a nested page of the App's making
    /// (history pages): choosing the action pushes the page in place.
    public var actionPages: [ActionID: @MainActor () -> PalettePageSpec?] = [:]

    public init(
        workspaces: (any PaletteWorkspaceSource)? = nil,
        tabs: (any PaletteTabSource)? = nil,
        openIn: (any PaletteOpenInSource)? = nil,
        settings: (any PaletteSettingsSource)? = nil,
        recentDirectories: (any PaletteRecentDirectorySource)? = nil,
        targets: (any PaletteTargetSource)? = nil,
        extraProviders: [any PaletteProvider] = [],
        context: (@MainActor () -> [ActionTargetRef])? = nil,
        argumentPreview: PaletteArgumentPreview? = nil
    ) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.openIn = openIn
        self.settings = settings
        self.recentDirectories = recentDirectories
        self.targets = targets
        self.extraProviders = extraProviders
        self.context = context
        self.argumentPreview = argumentPreview
    }
}

/// `(action, argument name, highlighted value or nil to revert, target)`.
public typealias PaletteArgumentPreview = @MainActor (ActionID, String, String?, ActionTargetRef?) -> Void

// MARK: - Providers over the sources

/// Shortens a home-relative path to `~/…`.
nonisolated func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
