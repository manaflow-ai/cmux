import AppKit
import CmuxFoundation
import Foundation

extension WorkspaceContentView {
    @MainActor
    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() },
        defaultBackground: (() -> NSColor)? = nil,
        defaultForeground: (() -> NSColor)? = nil,
        defaultCursor: (() -> NSColor)? = nil,
        defaultCursorText: (() -> NSColor)? = nil,
        defaultSelectionBackground: (() -> NSColor)? = nil,
        defaultSelectionForeground: (() -> NSColor)? = nil,
        defaultBackgroundOpacity: (() -> Double)? = nil
    ) -> GhosttyConfig {
        // The engine-runtime appearance reads are `@MainActor`; reading them
        // here (the function is `@MainActor`) avoids putting actor-isolated
        // reads in default-argument expressions, which Swift evaluates in a
        // nonisolated context.
        let runtime = GhosttyApp.shared.engineRuntime
        let resolveBackground = defaultBackground ?? { runtime.defaultBackgroundColor }
        let resolveForeground = defaultForeground ?? { runtime.defaultForegroundColor }
        let resolveCursor = defaultCursor ?? { runtime.defaultCursorColor }
        let resolveCursorText = defaultCursorText ?? { runtime.defaultCursorTextColor }
        let resolveSelectionBackground = defaultSelectionBackground ?? { runtime.defaultSelectionBackground }
        let resolveSelectionForeground = defaultSelectionForeground ?? { runtime.defaultSelectionForeground }
        let resolveBackgroundOpacity = defaultBackgroundOpacity ?? { runtime.defaultBackgroundOpacity }

        var next = loadConfig()
        let loadedBackgroundHex = next.backgroundColor.hexString()
        let loadedForegroundHex = next.foregroundColor.hexString()
        let resolvedBackground = backgroundOverride ?? resolveBackground()
        let defaultBackgroundHex = backgroundOverride == nil ? resolvedBackground.hexString() : "skipped"

        next.backgroundColor = resolvedBackground
        next.foregroundColor = resolveForeground()
        next.cursorColor = resolveCursor()
        next.cursorTextColor = resolveCursorText()
        next.selectionBackground = resolveSelectionBackground()
        next.selectionForeground = resolveSelectionForeground()
        next.backgroundOpacity = resolveBackgroundOpacity()

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) loadedFg=\(loadedForegroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) defaultFg=\(next.foregroundColor.hexString()) finalBg=\(next.backgroundColor.hexString()) finalFg=\(next.foregroundColor.hexString()) opacity=\(String(format: "%.3f", next.backgroundOpacity)) theme=\(next.theme ?? "nil")"
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
