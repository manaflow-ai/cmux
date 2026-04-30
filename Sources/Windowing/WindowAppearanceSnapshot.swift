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
    case bonsplitChrome
    case titlebar
    case leftSidebar
    case rightSidebar
    case browserSurface
}

enum GhosttyBackgroundBlur: Equatable {
    case disabled
    case radius(Int)
    case macosGlassRegular
    case macosGlassClear

    init(cValue value: Int16) {
        switch value {
        case 0:
            self = .disabled
        case -1:
            self = .macosGlassRegular
        case -2:
            self = .macosGlassClear
        case 1...:
            self = .radius(Int(value))
        default:
            self = .disabled
        }
    }

    var isMacOSGlassStyle: Bool {
        switch self {
        case .macosGlassRegular, .macosGlassClear:
            return true
        case .disabled, .radius:
            return false
        }
    }

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
        return cmuxShouldApplyWindowGlass(
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

    var appKitWindowMutationID: String {
        [
            terminalBackgroundColor.hexString(includeAlpha: true),
            String(format: "%.4f", Double(terminalBackgroundOpacity)),
            String(describing: terminalBackgroundBlur),
            String(describing: terminalRenderingMode),
            String(unifySurfaceBackdrops),
            sidebarSettings.appKitMutationID,
            windowGlassSettings.appKitMutationID,
        ].joined(separator: "|")
    }

    func shouldUseTransparentHosting(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        windowGlassSettings.shouldApply(glassEffectAvailable: glassEffectAvailable)
            || compositedTerminalBackgroundColor.alphaComponent < 0.999
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

    private func terminalBackdropPolicy() -> WindowBackdropPolicy {
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
