import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxSettings

/// Applies the app-wide chrome palette to a workspace's Bonsplit-owned chrome.
///
/// Bonsplit currently exposes background and separator hooks, but its active
/// tab/accent colors remain internal. This seam maps the public surface tokens
/// that Bonsplit can consume and leaves the remaining accent/drop/status hooks
/// to the SwiftUI/AppKit chrome owned by cmux. The terminal-derived base values
/// are retained so switching back to the default theme restores the existing
/// Ghostty-backed rendering exactly.
extension Workspace {
    /// Layers the Bonsplit-compatible surface tokens over terminal-derived
    /// colors, preserving the default palette's historical rendering when no
    /// relevant override is present.
    nonisolated static func chromeColorsApplyingPalette(
        _ baseColors: BonsplitConfiguration.Appearance.ChromeColors,
        palette: ChromePalette
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        var colors = baseColors
        if palette.isCustomized(.surface) {
            colors.backgroundHex = palette.surface.hex
            colors.paneBackgroundHex = palette.surface.hex
        }
        if palette.isCustomized(.surfaceRaised) {
            colors.tabBarBackgroundHex = palette.surfaceRaised.hex
            colors.splitButtonBackdropHex = palette.surfaceRaised.hex
        }
        if palette.isCustomized(.border) {
            colors.borderHex = palette.border.hex
        }
        return colors
    }

    /// Shared-backdrop mode makes Bonsplit's tab bar transparent. Disable it
    /// only when a user-selected surface must be painted by Bonsplit.
    nonisolated static func usesSharedBackdropApplyingPalette(
        _ baseValue: Bool,
        baseColors: BonsplitConfiguration.Appearance.ChromeColors?,
        palette: ChromePalette
    ) -> Bool {
        let surfaceCustomized = palette.isCustomized(.surface)
            || palette.isCustomized(.surfaceRaised)
        guard surfaceCustomized else { return baseValue }
        // A non-nil base is intentionally part of the seam: it documents that
        // this transition is only meaningful for a real Bonsplit appearance.
        return baseColors == nil ? baseValue : false
    }

    /// Applies `palette` to the current workspace and all Bonsplit surfaces.
    /// New Ghostty background events reapply the same snapshot automatically.
    func applyChromePalette(_ palette: ChromePalette) {
        chromePalette = palette
        guard let baseColors = chromeBaseColors else { return }

        let nextColors = Self.chromeColorsApplyingPalette(baseColors, palette: palette)
        let nextUsesSharedBackdrop = Self.usesSharedBackdropApplyingPalette(
            chromeBaseUsesSharedBackdrop,
            baseColors: baseColors,
            palette: palette
        )
        let currentAppearance = bonsplitController.configuration.appearance
        let colorsChanged = !Self.bonsplitChromeColorsEqual(
            currentAppearance.chromeColors,
            nextColors
        )
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextColors
        }
        if currentAppearance.usesSharedBackdrop != nextUsesSharedBackdrop {
            bonsplitController.configuration.appearance.usesSharedBackdrop = nextUsesSharedBackdrop
        }
    }

    /// Reapplies Ghostty-derived base colors with the current chrome palette.
    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeBackgroundColor = Self.resolvedTerminalChromeBackgroundColor(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity
        )
        let baseChromeColors = Self.bonsplitChromeColors(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode,
            paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
            chromeBackgroundColor: chromeBackgroundColor
        )
        chromeBaseColors = baseChromeColors
        chromeBaseUsesSharedBackdrop = sharesWindowBackdrop
        let nextChromeColors = Self.chromeColorsApplyingPalette(baseChromeColors, palette: chromePalette)
        let nextUsesSharedBackdrop = Self.usesSharedBackdropApplyingPalette(
            sharesWindowBackdrop,
            baseColors: baseChromeColors,
            palette: chromePalette
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let colorsChanged = !Self.bonsplitChromeColorsEqual(currentAppearance.chromeColors, nextChromeColors)
        let sharedBackdropChanged = currentAppearance.usesSharedBackdrop != nextUsesSharedBackdrop
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !colorsChanged && !sharedBackdropChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentAppearance.chromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) " +
                "sharesWindowBackdrop=\(nextUsesSharedBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentAppearance.usesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = nextUsesSharedBackdrop
        }
        if fontSizeChanged {
            bonsplitController.configuration.appearance.tabTitleFontSize = nextTabTitleFontSize
        }

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0) " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    /// Reapplies a direct Ghostty background update with the current palette.
    func applyGhosttyChrome(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        reason: String = "unspecified"
    ) {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeBackgroundColor = Self.resolvedTerminalChromeBackgroundColor(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let baseChromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode,
            paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
            chromeBackgroundColor: chromeBackgroundColor
        )
        chromeBaseColors = baseChromeColors
        chromeBaseUsesSharedBackdrop = sharesWindowBackdrop
        let nextChromeColors = Self.chromeColorsApplyingPalette(baseChromeColors, palette: chromePalette)
        let nextUsesSharedBackdrop = Self.usesSharedBackdropApplyingPalette(
            sharesWindowBackdrop,
            baseColors: baseChromeColors,
            palette: chromePalette
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let currentUsesSharedBackdrop = bonsplitController.configuration.appearance.usesSharedBackdrop
        let colorsChanged = !Self.bonsplitChromeColorsEqual(currentChromeColors, nextChromeColors)
        let sharedBackdropChanged = currentUsesSharedBackdrop != nextUsesSharedBackdrop
        let isNoOp = !colorsChanged && !sharedBackdropChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentChromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "sharesWindowBackdrop=\(nextUsesSharedBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentUsesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = nextUsesSharedBackdrop
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0)"
            )
        }
    }
}
