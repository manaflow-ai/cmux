import AppKit
import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// The runtime appearance/background-change notification dispatcher, drained out
/// of this app-target file into `CmuxTerminal` as
/// ``CmuxTerminal/TerminalDefaultBackgroundNotificationDispatcher``.
///
/// The alias keeps the legacy `GhosttyApp` construction and `signal(...)` call
/// sites byte-identical while the implementation, its coalescer, and the
/// appearance `userInfo` keys live in the package. The broadly-shared
/// `GhosttyNotificationKey` event vocabulary below stays here until its own
/// slice; its appearance-key raw values match the package's
/// ``CmuxTerminal/TerminalDefaultBackgroundUserInfoKey`` byte-for-byte, so a
/// payload built in the package is read here unchanged.
typealias GhosttyDefaultBackgroundNotificationDispatcher = TerminalDefaultBackgroundNotificationDispatcher

/// Read-only forwards for the default-appearance state drained off `GhosttyApp`
/// into ``CmuxTerminal/TerminalDefaultAppearanceState`` (held as
/// `GhosttyApp.appearanceState`). These keep every legacy
/// `GhosttyApp.shared.defaultBackgroundColor` / `app.defaultBackgroundBlur` /
/// `effectiveTerminalColorSchemePreference` read site (main window, browser
/// panel, right-sidebar style, titlebar accessory, workspace content, sidebar,
/// tab manager, debug controls) byte-identical. The setters live on the model;
/// the only writer is its scope-arbitrated `applyDefaultBackground`.
extension GhosttyApp {
    /// The resolved terminal background color.
    var defaultBackgroundColor: NSColor { appearanceState.defaultBackgroundColor }

    /// The resolved terminal background opacity.
    var defaultBackgroundOpacity: Double { appearanceState.defaultBackgroundOpacity }

    /// The resolved terminal background blur.
    var defaultBackgroundBlur: GhosttyBackgroundBlur { appearanceState.defaultBackgroundBlur }

    /// The resolved terminal foreground color.
    var defaultForegroundColor: NSColor { appearanceState.defaultForegroundColor }

    /// The resolved terminal cursor color.
    var defaultCursorColor: NSColor { appearanceState.defaultCursorColor }

    /// The resolved terminal cursor text color.
    var defaultCursorTextColor: NSColor { appearanceState.defaultCursorTextColor }

    /// The resolved terminal selection background color.
    var defaultSelectionBackground: NSColor { appearanceState.defaultSelectionBackground }

    /// The resolved terminal selection foreground color.
    var defaultSelectionForeground: NSColor { appearanceState.defaultSelectionForeground }

    /// The terminal color-scheme preference derived from the resolved background.
    var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference {
        appearanceState.effectiveTerminalColorSchemePreference
    }
}

/// The app-side seam ``CmuxTerminal/TerminalAppearanceCoordinator`` calls back
/// through for the cold appearance-sync effects that must stay on `GhosttyApp`:
/// the live `ghostty_app_t` color-scheme write, the configuration reload, the
/// background debug log, and the reload-reentrancy depth. The `ghostty_app_t`
/// handle never crosses into the package; `appearanceHasGhosttyApp` reports its
/// presence and `appearanceApplyGhosttyRuntimeColorScheme` performs the
/// `ghostty_app_set_color_scheme` against the private handle here.
extension GhosttyApp: TerminalAppearanceHosting {
    var appearanceBackgroundLogEnabled: Bool { backgroundLogEnabled }

    func appearanceLogBackground(_ message: String) {
        logBackground(message)
    }

    var appearanceHasGhosttyApp: Bool { app != nil }

    func appearanceApplyGhosttyRuntimeColorScheme(_ runtimeColorScheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, runtimeColorScheme)
    }

    func appearanceReloadConfiguration(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        reloadConfiguration(
            source: source,
            reloadSettingsFromFile: false,
            preferredColorScheme: preferredColorScheme
        )
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let explicitFocusIntent = "ghostty.explicitFocusIntent"
    static let title = "ghostty.title"
    static let backgroundColor = "ghostty.backgroundColor"
    static let backgroundOpacity = "ghostty.backgroundOpacity"
    static let backgroundEventId = "ghostty.backgroundEventId"
    static let backgroundSource = "ghostty.backgroundSource"
    static let foregroundColor = "ghostty.foregroundColor"
    static let cursorColor = "ghostty.cursorColor"
    static let cursorTextColor = "ghostty.cursorTextColor"
    static let selectionBackground = "ghostty.selectionBackground"
    static let selectionForeground = "ghostty.selectionForeground"
}
