import AppKit
public import SwiftUI
import CmuxFoundation

/// Persisted sidebar backdrop settings captured as a value.
public struct SidebarBackdropSettingsSnapshot {
    /// Raw `sidebarMaterial` value.
    public let materialRawValue: String

    /// Raw `sidebarBlendMode` value.
    public let blendModeRawValue: String

    /// Raw `sidebarState` value.
    public let stateRawValue: String

    /// Base tint hex value.
    public let tintHex: String

    /// Light-mode tint override.
    public let tintHexLight: String?

    /// Dark-mode tint override.
    public let tintHexDark: String?

    /// Tint opacity.
    public let tintOpacity: Double

    /// Material corner radius.
    public let cornerRadius: Double

    /// Material blur opacity.
    public let blurOpacity: Double

    /// Color scheme used to pick light/dark tint overrides.
    public let colorScheme: ColorScheme

    /// Creates a sidebar backdrop settings snapshot.
    public init(
        materialRawValue: String,
        blendModeRawValue: String,
        stateRawValue: String,
        tintHex: String,
        tintHexLight: String?,
        tintHexDark: String?,
        tintOpacity: Double,
        cornerRadius: Double,
        blurOpacity: Double,
        colorScheme: ColorScheme
    ) {
        self.materialRawValue = materialRawValue
        self.blendModeRawValue = blendModeRawValue
        self.stateRawValue = stateRawValue
        self.tintHex = tintHex
        self.tintHexLight = tintHexLight
        self.tintHexDark = tintHexDark
        self.tintOpacity = tintOpacity
        self.cornerRadius = cornerRadius
        self.blurOpacity = blurOpacity
        self.colorScheme = colorScheme
    }

    /// Resolved AppKit material policy for these settings.
    public var materialPolicy: SidebarBackdropMaterialPolicy {
        let materialOption = WindowChromeSidebarMaterialOption(rawValue: materialRawValue)
        let blendingMode = WindowChromeSidebarBlendModeOption(rawValue: blendModeRawValue)?.mode ?? .behindWindow
        let state = WindowChromeSidebarStateOption(rawValue: stateRawValue)?.state ?? .active
        // The sidebar reads as a flat Linear chrome panel per scheme (light
        // #F3F3F4, dark #13141C — matching the tab-bar strip) rather than a
        // translucent tint over a native `.sidebar` material, whose vibrancy
        // follows the window's NSAppearance and can stay dark in Light mode
        // regardless of a forced view appearance. Drawing an *opaque* scheme
        // color as the top tint layer makes the sidebar correct in both schemes.
        // A user-customized per-scheme tint override still applies translucently.
        let linearChromeHex = colorScheme == .dark ? "#13141C" : "#F3F3F4"
        let overrideHex = colorScheme == .dark ? tintHexDark : tintHexLight
        let resolvedHex = overrideHex ?? linearChromeHex
        let resolvedOpacity = overrideHex != nil ? tintOpacity : 1.0
        let fallbackColor: NSColor = colorScheme == .dark ? .black : .white
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: linearChromeHex) ?? fallbackColor)
            .withAlphaComponent(resolvedOpacity)
        let preferLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let usesWindowLevelGlass = preferLiquidGlass && blendingMode == .behindWindow

        return SidebarBackdropMaterialPolicy(
            material: materialOption?.material,
            blendingMode: blendingMode,
            state: state,
            opacity: blurOpacity,
            tintColor: tintColor,
            cornerRadius: CGFloat(max(0, cornerRadius)),
            preferLiquidGlass: preferLiquidGlass,
            usesWindowLevelGlass: usesWindowLevelGlass,
            // Force the native material's appearance to the app scheme so a
            // `.sidebar` NSVisualEffectView renders light in Light mode even if
            // the host window's NSAppearance is still dark.
            appearanceName: colorScheme == .dark ? .darkAqua : .aqua
        )
    }

    /// Stable identity for AppKit mutations.
    public var appKitMutationID: String {
        [
            materialRawValue,
            blendModeRawValue,
            stateRawValue,
            tintHex,
            tintHexLight ?? "nil",
            tintHexDark ?? "nil",
            identityComponent(tintOpacity),
            identityComponent(cornerRadius),
            identityComponent(blurOpacity),
            String(describing: colorScheme),
        ].joined(separator: "|")
    }

    private func identityComponent(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
