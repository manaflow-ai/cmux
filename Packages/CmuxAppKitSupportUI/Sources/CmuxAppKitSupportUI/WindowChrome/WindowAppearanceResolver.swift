import AppKit
public import SwiftUI
import CmuxFoundation

/// Builds `WindowAppearanceSnapshot` values from injected terminal and user settings.
public struct WindowAppearanceResolver {
    private let terminalAppearance: WindowTerminalAppearanceSnapshot

    /// Creates a resolver with the current terminal appearance injected by the app.
    public init(terminalAppearance: WindowTerminalAppearanceSnapshot) {
        self.terminalAppearance = terminalAppearance
    }

    /// Resolves window appearance from explicit user settings.
    public func current(settings: WindowAppearanceUserSettingsSnapshot) -> WindowAppearanceSnapshot {
        WindowAppearanceSnapshot(
            terminalBackgroundColor: terminalAppearance.backgroundColor,
            terminalBackgroundOpacity: WindowAppearanceSnapshot.clampedOpacity(terminalAppearance.backgroundOpacity),
            terminalBackgroundBlur: terminalAppearance.backgroundBlur,
            terminalRenderingMode: WindowAppearanceSnapshot.terminalRenderingMode(
                usesHostLayerBackground: terminalAppearance.usesHostLayerBackground
            ),
            unifySurfaceBackdrops: settings.unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: settings.sidebarMaterial,
                blendModeRawValue: settings.sidebarBlendMode,
                stateRawValue: settings.sidebarState,
                tintHex: settings.sidebarTintHex,
                tintHexLight: settings.sidebarTintHexLight,
                tintHexDark: settings.sidebarTintHexDark,
                tintOpacity: settings.sidebarTintOpacity,
                cornerRadius: settings.sidebarCornerRadius,
                blurOpacity: settings.sidebarBlurOpacity,
                colorScheme: settings.colorScheme
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: settings.sidebarBlendMode,
                isEnabled: settings.bgGlassEnabled,
                tintHex: settings.bgGlassTintHex,
                tintOpacity: settings.bgGlassTintOpacity,
                terminalBackgroundBlur: terminalAppearance.backgroundBlur,
                terminalGlassTintColor: terminalAppearance.backgroundColor.withAlphaComponent(
                    WindowAppearanceSnapshot.clampedOpacity(terminalAppearance.backgroundOpacity)
                )
            )
        )
    }

    /// Resolves window appearance from a `UserDefaults` store.
    public func currentFromUserDefaults(
        defaults: UserDefaults,
        colorScheme: ColorScheme
    ) -> WindowAppearanceSnapshot {
        let tintDefaults = WindowChromeSidebarTintDefaults()
        return current(settings: WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: defaults.object(forKey: "sidebarMatchTerminalBackground") as? Bool ?? false,
            colorScheme: colorScheme,
            sidebarMaterial: defaults.string(forKey: "sidebarMaterial") ?? WindowChromeSidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: defaults.string(forKey: "sidebarBlendMode") ?? WindowChromeSidebarBlendModeOption.withinWindow.rawValue,
            sidebarState: defaults.string(forKey: "sidebarState") ?? WindowChromeSidebarStateOption.followWindow.rawValue,
            sidebarTintHex: defaults.string(forKey: "sidebarTintHex") ?? tintDefaults.hex,
            sidebarTintHexLight: defaults.string(forKey: "sidebarTintHexLight"),
            sidebarTintHexDark: defaults.string(forKey: "sidebarTintHexDark"),
            sidebarTintOpacity: defaults.object(forKey: "sidebarTintOpacity") as? Double ?? tintDefaults.opacity,
            sidebarCornerRadius: defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0,
            sidebarBlurOpacity: defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 1.0,
            bgGlassEnabled: defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false,
            bgGlassTintHex: defaults.string(forKey: "bgGlassTintHex") ?? "#000000",
            bgGlassTintOpacity: defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03
        ))
    }
}
