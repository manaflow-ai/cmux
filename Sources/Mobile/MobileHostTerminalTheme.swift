import CMUXMobileCore
import CmuxFoundation
import CmuxTerminalCore
import Foundation

extension TerminalTheme {
    /// Builds the wire ``TerminalTheme`` from the Mac's resolved terminal config.
    ///
    /// `GhosttyConfig.load()` already folds a named `theme = <name>` directive
    /// (any of ghostty's bundled themes, e.g. `catppuccin-mocha`), cmux's managed
    /// default appearance, and the user's explicit `background=`/`palette=`
    /// overrides into concrete `NSColor`s, so reading those resolved colors here
    /// captures the *effective* palette for both custom configs and named ghostty
    /// themes. Any palette index the config did not populate falls back to the
    /// matching Monokai entry so the phone always receives a complete 16-color
    /// palette.
    init(ghosttyConfig config: GhosttyConfig) {
        let monokai = TerminalTheme.monokai
        let palette: [String] = (0...15).map { index in
            config.palette[index]?.hexString() ?? monokai.palette[index]
        }
        // Only carry cursor-text when the Mac config actually parsed a
        // `cursor-text` directive. When it did not, `config.cursorTextColor` is
        // just a placeholder default that ghostty never applies (it derives
        // cursor-text contrast automatically), so forwarding it would make the
        // phone emit an explicit `cursor-text` line the Mac never had and mis-
        // color the cursor label. `nil` here lets the phone derive contrast too.
        let cursorColorSemantic = config.cursorColorSemantic.flatMap {
            TerminalTheme.CellRelativeColor(rawValue: $0.rawValue)
        }
        let cursorTextSemantic = config.cursorTextColorSemantic.flatMap {
            TerminalTheme.CellRelativeColor(rawValue: $0.rawValue)
        }
        let selectionBackgroundSemantic = config.selectionBackgroundSemantic.flatMap {
            TerminalTheme.CellRelativeColor(rawValue: $0.rawValue)
        }
        let selectionForegroundSemantic = config.selectionForegroundSemantic.flatMap {
            TerminalTheme.CellRelativeColor(rawValue: $0.rawValue)
        }
        let cursorText = config.hasParsedCursorTextColor && cursorTextSemantic == nil
            ? config.cursorTextColor.hexString()
            : nil
        self.init(
            background: config.backgroundColor.hexString(),
            foreground: config.foregroundColor.hexString(),
            boldColor: config.boldColor,
            cursor: config.cursorColor.hexString(),
            cursorColorSemantic: cursorColorSemantic,
            cursorText: cursorText,
            cursorTextSemantic: cursorTextSemantic,
            selectionBackground: config.selectionBackground.hexString(),
            selectionBackgroundSemantic: selectionBackgroundSemantic,
            selectionForeground: config.selectionForeground.hexString(),
            selectionForegroundSemantic: selectionForegroundSemantic,
            palette: palette
        )
    }

    /// The JSON object the `mobile.host.status` payload carries under the
    /// `theme` key. Keys match ``TerminalTheme``'s synthesized `Codable`
    /// `CodingKeys` so the iOS side decodes it straight back into a
    /// ``TerminalTheme`` via ``MobileHostStatusResponse``.
    var mobileHostJSONObject: [String: Any] {
        var object: [String: Any] = [
            "background": background,
            "foreground": foreground,
            "cursor": cursor,
            "selectionBackground": selectionBackground,
            "selectionForeground": selectionForeground,
            "palette": palette,
        ]
        if let cursorText {
            object["cursorText"] = cursorText
        }
        if let boldColor {
            object["boldColor"] = boldColor
        }
        if let cursorColorSemantic {
            object["cursorColorSemantic"] = cursorColorSemantic.rawValue
        }
        if let cursorTextSemantic {
            object["cursorTextSemantic"] = cursorTextSemantic.rawValue
        }
        if let selectionBackgroundSemantic {
            object["selectionBackgroundSemantic"] = selectionBackgroundSemantic.rawValue
        }
        if let selectionForegroundSemantic {
            object["selectionForegroundSemantic"] = selectionForegroundSemantic.rawValue
        }
        return object
    }

    /// Captures the theme currently applied by the Mac Ghostty runtime.
    ///
    /// Unlike loading the config file again, this reads the same resolved
    /// appearance state that repaints Mac chrome after a config reload, so the
    /// frame sent to iOS cannot lag the visible Mac theme.
    @MainActor
    static func currentMacTerminalThemeSnapshot() -> TerminalTheme {
        let app = GhosttyApp.shared
        let config = GhosttyConfig.load(
            preferredColorScheme: app.effectiveTerminalColorSchemePreference,
            useCache: false,
            globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
        )
        let resolvedConfigTheme = TerminalTheme(ghosttyConfig: config)
        return TerminalTheme(
            background: app.defaultBackgroundColor.hexString(),
            foreground: app.defaultForegroundColor.hexString(),
            boldColor: resolvedConfigTheme.boldColor,
            cursor: app.defaultCursorColor.hexString(),
            cursorColorSemantic: resolvedConfigTheme.cursorColorSemantic,
            cursorText: resolvedConfigTheme.cursorText,
            cursorTextSemantic: resolvedConfigTheme.cursorTextSemantic,
            selectionBackground: app.defaultSelectionBackground.hexString(),
            selectionBackgroundSemantic: resolvedConfigTheme.selectionBackgroundSemantic,
            selectionForeground: app.defaultSelectionForeground.hexString(),
            selectionForegroundSemantic: resolvedConfigTheme.selectionForegroundSemantic,
            palette: resolvedConfigTheme.palette
        ).validatedOrDefault()
    }

    /// Returns this config-resolved theme with surface-effective OSC colors
    /// exported by one render-grid frame.
    func applyingSurfaceColors(from frame: MobileTerminalRenderGridFrame) -> TerminalTheme {
        // A renderer-exported theme has already resolved reverse-video and OSC
        // overrides together. The legacy outer fields are raw on older GhosttyKit
        // builds, so applying them again would undo that effective result.
        if let effectiveTheme = frame.terminalTheme {
            var resolved = effectiveTheme
            if resolved.boldColor == nil {
                resolved.boldColor = boldColor
            }
            return resolved.validatedOrDefault()
        }
        var resolved = self
        if let background = frame.terminalBackground,
           TerminalTheme.rgbComponents(background) != nil {
            resolved.background = background
        }
        if let foreground = frame.terminalForeground,
           TerminalTheme.rgbComponents(foreground) != nil {
            resolved.foreground = foreground
        }
        if frame.modes.contains(where: { !$0.ansi && $0.code == 5 && $0.on }) {
            let foreground = resolved.foreground
            resolved.foreground = resolved.background
            resolved.background = foreground
        }
        if let cursor = frame.terminalCursorColor,
           TerminalTheme.rgbComponents(cursor) != nil {
            resolved.cursor = cursor
            resolved.cursorColorSemantic = nil
        }
        return resolved
    }
}
