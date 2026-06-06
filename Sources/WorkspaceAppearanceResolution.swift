import AppKit
import Foundation

extension WorkspaceContentView {
    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        workspaceTheme: WorkspaceGhosttyThemeSelection? = nil,
        loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() },
        defaultBackground: () -> NSColor = { GhosttyApp.shared.defaultBackgroundColor },
        defaultForeground: () -> NSColor = { GhosttyApp.shared.defaultForegroundColor },
        defaultCursor: () -> NSColor = { GhosttyApp.shared.defaultCursorColor },
        defaultCursorText: () -> NSColor = { GhosttyApp.shared.defaultCursorTextColor },
        defaultSelectionBackground: () -> NSColor = { GhosttyApp.shared.defaultSelectionBackground },
        defaultSelectionForeground: () -> NSColor = { GhosttyApp.shared.defaultSelectionForeground },
        defaultBackgroundOpacity: () -> Double = { GhosttyApp.shared.defaultBackgroundOpacity },
        preferredColorScheme: () -> GhosttyConfig.ColorSchemePreference = { GhosttyApp.shared.effectiveTerminalColorSchemePreference }
    ) -> GhosttyConfig {
        let workspaceThemeColorScheme = workspaceTheme == nil
            ? preferredColorScheme()
            : GhosttyConfig.currentColorSchemePreference()
        var next = workspaceTheme?.resolvedGhosttyConfig(preferredColorScheme: workspaceThemeColorScheme) ?? loadConfig()
        let loadedBackgroundHex = next.backgroundColor.hexString()
        let loadedForegroundHex = next.foregroundColor.hexString()
        let hasWorkspaceTheme = workspaceTheme != nil
        let resolvedBackground = backgroundOverride ?? (hasWorkspaceTheme ? next.backgroundColor : defaultBackground())
        let defaultBackgroundHex = backgroundOverride == nil ? resolvedBackground.hexString() : "skipped"

        next.backgroundColor = resolvedBackground
        if !hasWorkspaceTheme {
            next.foregroundColor = defaultForeground()
            next.cursorColor = defaultCursor()
            next.cursorTextColor = defaultCursorText()
            next.selectionBackground = defaultSelectionBackground()
            next.selectionForeground = defaultSelectionForeground()
        }
        next.backgroundOpacity = hasWorkspaceTheme ? next.backgroundOpacity : defaultBackgroundOpacity()

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) loadedFg=\(loadedForegroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) defaultFg=\(next.foregroundColor.hexString()) finalBg=\(next.backgroundColor.hexString()) finalFg=\(next.foregroundColor.hexString()) opacity=\(String(format: "%.3f", next.backgroundOpacity)) theme=\(next.theme ?? "nil") workspaceTheme=\(workspaceTheme?.displayName ?? "nil")"
            )
        }
        return next
    }

    static func ghosttyAppearanceSignature(_ config: GhosttyConfig, usesHostLayerBackground: Bool) -> String {
        [
            config.backgroundColor.hexString(includeAlpha: true),
            config.foregroundColor.hexString(includeAlpha: true),
            config.cursorColor.hexString(includeAlpha: true),
            config.cursorTextColor.hexString(includeAlpha: true),
            config.selectionBackground.hexString(includeAlpha: true),
            config.selectionForeground.hexString(includeAlpha: true),
            String(format: "%.4f", config.backgroundOpacity),
            String(describing: config.backgroundBlur),
            String(format: "%.4f", config.surfaceTabBarFontSize),
            String(format: "%.4f", config.unfocusedSplitOpacity),
            config.unfocusedSplitFill?.hexString(includeAlpha: true) ?? "nil",
            config.splitDividerColor?.hexString(includeAlpha: true) ?? "nil",
            String(usesHostLayerBackground),
        ].joined(separator: "|")
    }
}
