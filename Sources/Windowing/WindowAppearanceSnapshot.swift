import AppKit
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
    case workspaceSplitChrome
    case titlebar
    case leftSidebar
    case rightSidebar
    case browserSurface
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
}

struct WindowGlassSettingsSnapshot {
    let sidebarBlendModeRawValue: String
    let isEnabled: Bool
    let tintHex: String
    let tintOpacity: Double

    var tintColor: NSColor {
        (NSColor(hex: tintHex) ?? .black).withAlphaComponent(tintOpacity)
    }

    func shouldApply(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        cmuxShouldApplyWindowGlass(
            sidebarBlendMode: sidebarBlendModeRawValue,
            bgGlassEnabled: isEnabled,
            glassEffectAvailable: glassEffectAvailable
        )
    }
}

struct WindowAppearanceSnapshot {
    let terminalBackgroundColor: NSColor
    let terminalBackgroundOpacity: CGFloat
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
                tintOpacity: bgGlassTintOpacity
            )
        )
    }

    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    static func compositedTerminalColor(backgroundColor: NSColor, opacity: Double) -> NSColor {
        backgroundColor.withAlphaComponent(clampedOpacity(opacity))
    }

    static func terminalRenderingMode(
        usesHostLayerBackground: Bool
    ) -> GhosttyTerminalBackdropRenderingMode {
        usesHostLayerBackground ? .windowHostBackdrop : .ghosttyRendererOwnedBackgroundImage
    }

    var compositedTerminalBackgroundColor: NSColor {
        terminalBackgroundColor.withAlphaComponent(terminalBackgroundOpacity)
    }

    func shouldUseTransparentHosting(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        windowGlassSettings.shouldApply(glassEffectAvailable: glassEffectAvailable)
            || compositedTerminalBackgroundColor.alphaComponent < 0.999
    }

    func policy(for role: WindowBackdropRole) -> WindowBackdropPolicy {
        switch role {
        case .windowRoot:
            return terminalBackdropPolicy()
        case .terminalCanvas, .workspaceSplitChrome, .titlebar, .browserSurface:
            return .clear
        case .leftSidebar, .rightSidebar:
            if unifySurfaceBackdrops {
                return .clear
            }
            return .sidebarMaterial(sidebarSettings.materialPolicy)
        }
    }

    private func terminalBackdropPolicy() -> WindowBackdropPolicy {
        .ghosttyTerminalBackdrop(
            color: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity,
            renderingMode: terminalRenderingMode
        )
    }
}
