import CMUXMobileCore
import CmuxFoundation
import CmuxTerminalCore
import Foundation
import os

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
        func semantic<S: RawRepresentable>(
            _ value: S?
        ) -> TerminalTheme.CellRelativeColor? where S.RawValue == String {
            value.flatMap { TerminalTheme.CellRelativeColor(rawValue: $0.rawValue) }
        }
        let cursorTextSemantic = semantic(config.cursorTextColorSemantic)
        // Only carry cursor-text when the Mac config actually parsed a
        // `cursor-text` directive. When it did not, `config.cursorTextColor` is
        // just a placeholder default that ghostty never applies (it derives
        // cursor-text contrast automatically), so forwarding it would make the
        // phone emit an explicit `cursor-text` line the Mac never had and mis-
        // color the cursor label. `nil` here lets the phone derive contrast too.
        let cursorText = config.hasParsedCursorTextColor && cursorTextSemantic == nil
            ? config.cursorTextColor.hexString()
            : nil
        self.init(
            background: config.backgroundColor.hexString(),
            foreground: config.foregroundColor.hexString(),
            boldColor: config.boldColor,
            cursor: config.cursorColor.hexString(),
            cursorColorSemantic: semantic(config.cursorColorSemantic),
            cursorText: cursorText,
            cursorTextSemantic: cursorTextSemantic,
            selectionBackground: config.selectionBackground.hexString(),
            selectionBackgroundSemantic: semantic(config.selectionBackgroundSemantic),
            selectionForeground: config.selectionForeground.hexString(),
            selectionForegroundSemantic: semantic(config.selectionForegroundSemantic),
            palette: palette
        )
    }

    /// The JSON object the `mobile.host.status` payload carries under the
    /// `theme` key. Derived from ``TerminalTheme``'s synthesized `Codable`
    /// encoding, so the keys are by construction the `CodingKeys` the iOS
    /// side decodes straight back into a ``TerminalTheme`` via
    /// ``MobileHostStatusResponse``.
    var mobileHostJSONObject: [String: Any] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
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
        // Config-resolved theme, with the runtime colors GhosttyApp paints with overlaid.
        var theme = TerminalTheme(ghosttyConfig: config)
        theme.background = app.defaultBackgroundColor.hexString()
        theme.foreground = app.defaultForegroundColor.hexString()
        theme.cursor = app.defaultCursorColor.hexString()
        theme.selectionBackground = app.defaultSelectionBackground.hexString()
        theme.selectionForeground = app.defaultSelectionForeground.hexString()
        return theme.validatedOrDefault()
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

/// Single source of the Mac's resolved terminal theme for every mobile
/// consumer: render-grid frames, replay decoration, and the
/// `mobile.host.status` payload all read the same cached
/// ``TerminalTheme/currentMacTerminalThemeSnapshot()``, so status colors can
/// never disagree with the frames the phone renders.
@MainActor
enum MobileTerminalThemeResolver {
    private static var cachedTheme: TerminalTheme?
    private static var observersInstalled = false
    /// The last MainActor-resolved theme, mirrored behind a lock so the
    /// nonisolated status-payload builders can read it from any thread.
    private nonisolated static let latestResolvedTheme =
        OSAllocatedUnfairLock<TerminalTheme?>(initialState: nil)

    /// Installs process-lifetime invalidation observers and seeds the cache.
    /// Called once at app startup, before the mobile listener serves status.
    static func start() {
        guard !observersInstalled else { return }
        observersInstalled = true
        for name: Notification.Name in [.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    cachedTheme = nil
                    // Eager, so nonisolated status readers never serve colors older than this reload.
                    _ = resolvedTheme()
                }
            }
        }
        _ = resolvedTheme()
    }

    /// The Mac's effective terminal theme, resolved at most once between
    /// invalidations.
    static func resolvedTheme() -> TerminalTheme {
        if let cachedTheme { return cachedTheme }
        let theme = TerminalTheme.currentMacTerminalThemeSnapshot()
        cachedTheme = theme
        latestResolvedTheme.withLock { $0 = theme }
        return theme
    }

    /// The theme the `mobile.host.status` payload carries: the last MainActor-
    /// resolved snapshot, or (before the first resolution, early startup only)
    /// the config-file theme the payload historically used.
    nonisolated static func statusPayloadTheme() -> TerminalTheme {
        latestResolvedTheme.withLock { $0 } ?? TerminalTheme(ghosttyConfig: GhosttyConfig.load())
    }
}
