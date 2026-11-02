import AppKit
import CmuxNextActions

/// The catalog's Help placements (`mainMenu: .help`): the compact Support rows
/// (`compactMainMenuItems`). The Edit placements (Find…, Toggle
/// Dictation) stay out of the bar for now: as menu key equivalents they would
/// claim keys a user's Ghostty keybinds and panels expect (cmuxterm-hq#2015 C11).
extension MainMenu {
    static func helpPlacements(_ registry: ActionRegistry) -> [NSMenuItem] {
        // Keep Support focused; Feature Flags, Cloud Diagnostics and Share remain
        // palette-searchable instead of occupying peer rows in Help.
        MainMenu.compactMainMenuItems(for: .help, registry: registry)
    }
}
