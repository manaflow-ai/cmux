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

    /// Whether the sidebar glass is a clear window ground with a compositor
    /// blur behind it (tint painted on top) instead of an AppKit material.
    /// This is the only path with an adjustable blur radius.
    public let compositorGlass: Bool

    /// Compositor blur radius in points, used when `compositorGlass` is on.
    /// Read through `effectiveCompositorBlurRadius`, which clamps it.
    public let compositorBlurRadius: Double

    /// Blur radius bounds in points. Mirrors the settings catalog's range
    /// (this module cannot import it): a floor so the sidebar always reads
    /// as glass, a ceiling before blur turns to smear.
    public static let compositorBlurRadiusRange: ClosedRange<Double> = 12...60

    /// The blur radius the window actually receives, clamped to the range.
    public var effectiveCompositorBlurRadius: Int {
        let range = Self.compositorBlurRadiusRange
        return Int(min(range.upperBound, max(range.lowerBound, compositorBlurRadius)).rounded())
    }

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
        colorScheme: ColorScheme,
        compositorGlass: Bool = true,
        compositorBlurRadius: Double = Self.compositorBlurRadiusRange.lowerBound
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
        self.compositorGlass = compositorGlass
        self.compositorBlurRadius = compositorBlurRadius
    }

    /// Tint-only policy for the compositor-glass path: the window ground is
    /// clear and the compositor blurs behind it, so the sidebar layer paints
    /// just the tint. No effect view is created for a nil material.
    ///
    /// Chosen by `WindowAppearanceSnapshot`, which owns the decision, so the
    /// layer can never go tint-only over a ground that stayed opaque.
    public var tintOnlyMaterialPolicy: SidebarBackdropMaterialPolicy {
        SidebarBackdropMaterialPolicy(
            material: nil,
            blendingMode: .behindWindow,
            state: .active,
            opacity: 1.0,
            tintColor: resolvedTintColor,
            cornerRadius: CGFloat(max(0, cornerRadius)),
            preferLiquidGlass: false,
            usesWindowLevelGlass: false
        )
    }

    /// Resolved AppKit material policy for these settings.
    public var materialPolicy: SidebarBackdropMaterialPolicy {
        let materialOption = WindowChromeSidebarMaterialOption(rawValue: materialRawValue)
        let blendingMode = WindowChromeSidebarBlendModeOption(rawValue: blendModeRawValue)?.mode ?? .behindWindow
        let state = WindowChromeSidebarStateOption(rawValue: stateRawValue)?.state ?? .active
        let preferLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let usesWindowLevelGlass = preferLiquidGlass && blendingMode == .behindWindow

        return SidebarBackdropMaterialPolicy(
            material: materialOption?.material,
            blendingMode: blendingMode,
            state: state,
            opacity: blurOpacity,
            tintColor: resolvedTintColor,
            cornerRadius: CGFloat(max(0, cornerRadius)),
            preferLiquidGlass: preferLiquidGlass,
            usesWindowLevelGlass: usesWindowLevelGlass
        )
    }

    /// The tint colour with its opacity baked in, honouring the per-scheme
    /// overrides.
    private var resolvedTintColor: NSColor {
        let resolvedHex: String
        if colorScheme == .dark, let tintHexDark {
            resolvedHex = tintHexDark
        } else if colorScheme == .light, let tintHexLight {
            resolvedHex = tintHexLight
        } else {
            resolvedHex = tintHex
        }
        return (NSColor(hex: resolvedHex) ?? NSColor(hex: tintHex) ?? .black)
            .withAlphaComponent(tintOpacity)
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
            String(compositorGlass),
            identityComponent(compositorBlurRadius),
        ].joined(separator: "|")
    }

    private func identityComponent(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
