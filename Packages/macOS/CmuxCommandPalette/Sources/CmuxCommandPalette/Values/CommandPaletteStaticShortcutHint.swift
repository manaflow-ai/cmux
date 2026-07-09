import Foundation

/// The built-in, configuration-independent keyboard-shortcut hint for a palette
/// command, keyed by command identifier.
///
/// Some palette commands display a fixed shortcut glyph (for example `⌘W` for
/// `palette.closeTab`) that does not come from the user's configurable keyboard
/// shortcuts or from `cmux.json`. The host consults this *after* the configured
/// and `KeyboardShortcutSettings`-derived hints and *before* falling back to a
/// contribution's own `shortcutHint`, so the lookup table reproduces the legacy
/// `ContentView.commandPaletteStaticShortcutHint(for:)` switch byte-for-byte.
///
/// These glyphs are pure data with no receiver type, so they resolve on
/// construction (mirroring ``CommandPaletteCommandRunPlan``) rather than living
/// behind a static-only utility.
public struct CommandPaletteStaticShortcutHint: Sendable, Equatable {
    /// The resolved hint glyph, or `nil` when the command has no built-in
    /// static shortcut.
    public let value: String?

    /// Resolves the built-in static hint for `commandId`.
    ///
    /// - Parameter commandId: The palette command identifier.
    public init(commandId: String) {
        switch commandId {
        case "palette.closeTab":
            value = "⌘W"
        case "palette.closeWorkspace":
            value = "⌘⇧W"
        case "palette.openSettings":
            value = "⌘,"
        case "palette.browserBack":
            value = "⌘["
        case "palette.browserForward":
            value = "⌘]"
        case "palette.browserReload":
            value = "⌘R"
        case "palette.browserFocusAddressBar":
            value = "⌘L"
        case "palette.browserZoomIn":
            value = "⌘="
        case "palette.browserZoomOut":
            value = "⌘-"
        case "palette.browserZoomReset":
            value = "⌘0"
        case "palette.markdownZoomIn":
            value = "⌘="
        case "palette.markdownZoomOut":
            value = "⌘-"
        case "palette.markdownZoomReset":
            value = "⌘0"
        case "palette.terminalFind":
            value = "⌘F"
        case "palette.terminalFindNext":
            value = "⌘G"
        case "palette.terminalFindPrevious":
            value = "⌥⌘G"
        case "palette.terminalHideFind":
            value = "⌥⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            value = "⌘E"
        case "palette.toggleFullScreen":
            value = "\u{2303}\u{2318}F"
        default:
            value = nil
        }
    }
}
