import AppKit
import CmuxFoundation
import SwiftUI

enum GhosttyTerminalBackdropRenderingMode {
    case windowHostBackdrop
    case ghosttyRendererOwnedBackgroundImage

    var usesWindowHostBackdrop: Bool {
        self == .windowHostBackdrop
    }
}

enum WindowBackdropRole {
    case windowRoot
    case terminalCanvas
    case bonsplitChrome
    case titlebar
    case leftSidebar
    case rightSidebar
    case browserSurface
}

extension GhosttyBackgroundBlur {
    /// The window-chrome glass style for this blur mode, or `nil` when the mode
    /// is a compositor blur or disabled. Lives app-side because
    /// `WindowGlassEffect` is a window-domain type the terminal core must not
    /// depend on.
    var windowGlassStyle: WindowGlassEffect.Style? {
        switch self {
        case .macosGlassRegular:
            return .regular
        case .macosGlassClear:
            return .clear
        case .disabled, .radius:
            return nil
        }
    }
}

struct SidebarBackdropMaterialPolicy {
    let material: NSVisualEffectView.Material?
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool
    let usesWindowLevelGlass: Bool
}

enum WindowBackdropPolicy {
    case ghosttyTerminalBackdrop(
        color: NSColor,
        opacity: CGFloat,
        renderingMode: GhosttyTerminalBackdropRenderingMode
    )
    case sidebarMaterial(SidebarBackdropMaterialPolicy)
    case clear

    var hostLayerBackgroundColor: NSColor? {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            guard renderingMode.usesWindowHostBackdrop else { return nil }
            return color.withAlphaComponent(opacity)
        case .sidebarMaterial, .clear:
            return nil
        }
    }
}

/// Identifies the layer responsible for painting a terminal surface background.
enum TerminalSurfaceBackgroundFillOwner: Equatable {
    /// The terminal hosting view should paint the resolved background color.
    case surfaceHostLayer

    /// The shared root backdrop should remain the only visible background fill.
    case sharedWindowBackdrop

    /// The Bonsplit pane backdrop should remain the only visible background fill.
    case bonsplitPaneBackdrop

    /// Ghostty's renderer owns the background instead of cmux's host layers.
    case ghosttyNativeRenderer
}

/// Resolved background painting decision for one terminal surface.
struct TerminalSurfaceBackgroundFillPlan {
    /// The layer or renderer that owns the visible terminal background.
    let owner: TerminalSurfaceBackgroundFillOwner

    /// The color to apply to the terminal host layer, or clear when another layer owns the fill.
    let hostLayerColor: NSColor

    /// Whether a host-layer fill must subtract itself from the shared window backdrop.
    let clearsSharedWindowBackdrop: Bool

    /// Whether the terminal host layer should paint a non-clear fill.
    var usesHostLayerFill: Bool {
        owner == .surfaceHostLayer
    }

    /// Compact label used by debug logging for the selected backdrop owner.
    var logBackdropLabel: String {
        switch owner {
        case .surfaceHostLayer:
            return "terminal"
        case .sharedWindowBackdrop:
            return "shared"
        case .bonsplitPaneBackdrop:
            return "bonsplit-pane"
        case .ghosttyNativeRenderer:
            return "ghostty-native"
        }
    }

    /// Returns the debug-log source label for the selected owner.
    func logSource(hasSurfaceOverride: Bool) -> String {
        switch owner {
        case .surfaceHostLayer:
            return hasSurfaceOverride ? "surfaceOverride" : "defaultBackground"
        case .sharedWindowBackdrop:
            return "sharedWindowBackdrop"
        case .bonsplitPaneBackdrop:
            return "bonsplitPaneBackdrop"
        case .ghosttyNativeRenderer:
            return "ghosttyNativeBackground"
        }
    }

    /// Computes the terminal background owner and host-layer color for current appearance state.
    static func resolve(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        surfaceBackgroundColor: NSColor?,
        defaultBackgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool,
        usesBonsplitPaneBackdrop: Bool
    ) -> Self {
        let resolvedColor = (surfaceBackgroundColor ?? defaultBackgroundColor)
            .withAlphaComponent(WindowAppearanceSnapshot.clampedOpacity(backgroundOpacity))
        let owner: TerminalSurfaceBackgroundFillOwner
        let usesPaneLocalSurfaceFill = surfaceBackgroundColor != nil &&
            renderingMode.usesWindowHostBackdrop &&
            !usesBonsplitPaneBackdrop
        if !renderingMode.usesWindowHostBackdrop {
            owner = .ghosttyNativeRenderer
        } else if usesPaneLocalSurfaceFill {
            owner = .surfaceHostLayer
        } else if !sharesWindowBackdrop && !usesBonsplitPaneBackdrop {
            owner = .surfaceHostLayer
        } else if sharesWindowBackdrop {
            owner = .sharedWindowBackdrop
        } else {
            owner = .bonsplitPaneBackdrop
        }
        return Self(
            owner: owner,
            hostLayerColor: owner == .surfaceHostLayer ? resolvedColor : .clear,
            clearsSharedWindowBackdrop: usesPaneLocalSurfaceFill && sharesWindowBackdrop
        )
    }
}

struct SidebarBackdropSettingsSnapshot {
    let materialRawValue: String
    let blendModeRawValue: String
    let stateRawValue: String
    let tintHex: String
    let tintHexLight: String?
    let tintHexDark: String?
    let tintOpacity: Double
    let cornerRadius: Double
    let blurOpacity: Double
    let colorScheme: ColorScheme

    var materialPolicy: SidebarBackdropMaterialPolicy {
        let materialOption = SidebarMaterialOption(rawValue: materialRawValue)
        let blendingMode = SidebarBlendModeOption(rawValue: blendModeRawValue)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: stateRawValue)?.state ?? .active
        let resolvedHex: String
        if colorScheme == .dark, let tintHexDark {
            resolvedHex = tintHexDark
        } else if colorScheme == .light, let tintHexLight {
            resolvedHex = tintHexLight
        } else {
            resolvedHex = tintHex
        }
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: tintHex) ?? .black)
            .withAlphaComponent(tintOpacity)
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
            usesWindowLevelGlass: usesWindowLevelGlass
        )
    }

    var appKitMutationID: String {
        [
            materialRawValue,
            blendModeRawValue,
            stateRawValue,
            tintHex,
            tintHexLight ?? "nil",
            tintHexDark ?? "nil",
            Self.identityComponent(tintOpacity),
            Self.identityComponent(cornerRadius),
            Self.identityComponent(blurOpacity),
            String(describing: colorScheme),
        ].joined(separator: "|")
    }

    private static func identityComponent(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

struct WindowGlassSettingsSnapshot {
    let sidebarBlendModeRawValue: String
    let isEnabled: Bool
    let tintHex: String
    let tintOpacity: Double
    let terminalBackgroundBlur: GhosttyBackgroundBlur
    let terminalGlassTintColor: NSColor?

    init(
        sidebarBlendModeRawValue: String,
        isEnabled: Bool,
        tintHex: String,
        tintOpacity: Double,
        terminalBackgroundBlur: GhosttyBackgroundBlur = .disabled,
        terminalGlassTintColor: NSColor? = nil
    ) {
        self.sidebarBlendModeRawValue = sidebarBlendModeRawValue
        self.isEnabled = isEnabled
        self.tintHex = tintHex
        self.tintOpacity = tintOpacity
        self.terminalBackgroundBlur = terminalBackgroundBlur
        self.terminalGlassTintColor = terminalGlassTintColor
    }

    var tintColor: NSColor {
        if let terminalGlassTintColor, terminalBackgroundBlur.isMacOSGlassStyle {
            return terminalGlassTintColor
        }
        return (NSColor(hex: tintHex) ?? .black).withAlphaComponent(tintOpacity)
    }

    var style: WindowGlassEffect.Style {
        terminalBackgroundBlur.windowGlassStyle ?? .regular
    }

    func shouldApply(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return true
        }
        return WindowBackgroundComposition.policy.shouldApplyWindowGlass(
            sidebarBlendMode: sidebarBlendModeRawValue,
            bgGlassEnabled: isEnabled,
            glassEffectAvailable: glassEffectAvailable
        )
    }

    var appKitMutationID: String {
        [
            sidebarBlendModeRawValue,
            String(isEnabled),
            tintHex,
            String(format: "%.4f", tintOpacity),
            String(describing: terminalBackgroundBlur),
            terminalGlassTintColor?.hexString(includeAlpha: true) ?? "nil",
        ].joined(separator: "|")
    }
}

struct WindowAppearanceSnapshot {
    let terminalBackgroundColor: NSColor
    let terminalBackgroundOpacity: CGFloat
    let terminalBackgroundBlur: GhosttyBackgroundBlur
    let terminalRenderingMode: GhosttyTerminalBackdropRenderingMode
    let unifySurfaceBackdrops: Bool
    let sidebarSettings: SidebarBackdropSettingsSnapshot
    let windowGlassSettings: WindowGlassSettingsSnapshot

    static func current(
        unifySurfaceBackdrops: Bool,
        colorScheme: ColorScheme,
        sidebarMaterial: String,
        sidebarBlendMode: String,
        sidebarState: String,
        sidebarTintHex: String,
        sidebarTintHexLight: String?,
        sidebarTintHexDark: String?,
        sidebarTintOpacity: Double,
        sidebarCornerRadius: Double,
        sidebarBlurOpacity: Double,
        bgGlassEnabled: Bool,
        bgGlassTintHex: String,
        bgGlassTintOpacity: Double,
        app: GhosttyApp = .shared
    ) -> Self {
        Self(
            terminalBackgroundColor: app.defaultBackgroundColor,
            terminalBackgroundOpacity: Self.clampedOpacity(app.defaultBackgroundOpacity),
            terminalBackgroundBlur: app.defaultBackgroundBlur,
            terminalRenderingMode: Self.terminalRenderingMode(
                usesHostLayerBackground: app.usesHostLayerBackground
            ),
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: sidebarMaterial,
                blendModeRawValue: sidebarBlendMode,
                stateRawValue: sidebarState,
                tintHex: sidebarTintHex,
                tintHexLight: sidebarTintHexLight,
                tintHexDark: sidebarTintHexDark,
                tintOpacity: sidebarTintOpacity,
                cornerRadius: sidebarCornerRadius,
                blurOpacity: sidebarBlurOpacity,
                colorScheme: colorScheme
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: sidebarBlendMode,
                isEnabled: bgGlassEnabled,
                tintHex: bgGlassTintHex,
                tintOpacity: bgGlassTintOpacity,
                terminalBackgroundBlur: app.defaultBackgroundBlur,
                terminalGlassTintColor: app.defaultBackgroundColor.withAlphaComponent(
                    Self.clampedOpacity(app.defaultBackgroundOpacity)
                )
            )
        )
    }

    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    static func compositedTerminalColor(
        backgroundColor: NSColor,
        opacity: Double,
        over baseColor: NSColor = .windowBackgroundColor
    ) -> NSColor {
        cmuxCompositedNSColor(
            backgroundColor.withAlphaComponent(clampedOpacity(opacity)),
            over: baseColor
        )
    }

    static func terminalRenderingMode(
        usesHostLayerBackground: Bool
    ) -> GhosttyTerminalBackdropRenderingMode {
        usesHostLayerBackground ? .windowHostBackdrop : .ghosttyRendererOwnedBackgroundImage
    }

    var compositedTerminalBackgroundColor: NSColor {
        Self.compositedTerminalColor(
            backgroundColor: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity
        )
    }

    var chromeColorScheme: ColorScheme {
        cmuxReadableColorScheme(for: compositedTerminalBackgroundColor)
    }

    var sidebarContentColorScheme: ColorScheme {
        unifySurfaceBackdrops ? chromeColorScheme : sidebarSettings.colorScheme
    }

    func policy(for role: WindowBackdropRole) -> WindowBackdropPolicy {
        switch role {
        case .windowRoot:
            return terminalBackdropPolicy()
        case .terminalCanvas, .bonsplitChrome, .titlebar, .browserSurface:
            return .clear
        case .leftSidebar, .rightSidebar:
            if unifySurfaceBackdrops {
                return .clear
            }
            return .sidebarMaterial(sidebarSettings.materialPolicy)
        }
    }

    func terminalBackdropPolicy() -> WindowBackdropPolicy {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return .clear
        }
        return .ghosttyTerminalBackdrop(
            color: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity,
            renderingMode: terminalRenderingMode
        )
    }
}
