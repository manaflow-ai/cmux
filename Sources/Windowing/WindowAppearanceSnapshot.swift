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

enum WindowBackdropHostingPhase: String, Equatable {
    case opaqueWindowFill
    case transparentRootBackdrop
    case windowGlass
}

struct WindowBackdropGlassPlan {
    let tintColor: NSColor
    let style: WindowGlassEffect.Style
}

struct WindowBackdropPlan {
    let hostingPhase: WindowBackdropHostingPhase
    let windowBackgroundColor: NSColor
    let windowIsOpaque: Bool
    let rootPolicy: WindowBackdropPolicy
    let glass: WindowBackdropGlassPlan?
    let shouldApplyGhosttyCompositorBlur: Bool

    var usesTransparentWindow: Bool {
        hostingPhase != .opaqueWindowFill
    }

    var usesWindowGlass: Bool {
        hostingPhase == .windowGlass
    }

    var shouldClearContentViewHierarchy: Bool {
        false
    }

    var appKitMutationID: String {
        [
            hostingPhase.rawValue,
            windowBackgroundColor.hexString(includeAlpha: true),
            String(windowIsOpaque),
            rootPolicy.identityComponent,
            glass?.tintColor.hexString(includeAlpha: true) ?? "nil",
            glass.map { String(describing: $0.style) } ?? "nil",
            String(shouldApplyGhosttyCompositorBlur),
        ].joined(separator: "|")
    }
}

struct WindowBackdropApplicationResult {
    let didChangeGlassRoot: Bool
    let usesWindowGlass: Bool
}

enum WindowBackdropController {
    static func apply(
        snapshot: WindowAppearanceSnapshot,
        to window: NSWindow,
        glassEffectAvailable: Bool = WindowGlassEffect.isAvailable
    ) -> WindowBackdropApplicationResult {
        apply(plan: snapshot.backdropPlan(glassEffectAvailable: glassEffectAvailable), to: window)
    }

    static func apply(
        plan: WindowBackdropPlan,
        to window: NSWindow
    ) -> WindowBackdropApplicationResult {
        var didChangeGlassRoot = false

        switch plan.hostingPhase {
        case .opaqueWindowFill:
            didChangeGlassRoot = WindowGlassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = plan.windowIsOpaque
            cmuxResetCompositorBackgroundBlur(on: window)
        case .transparentRootBackdrop:
            didChangeGlassRoot = WindowGlassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            if plan.shouldApplyGhosttyCompositorBlur {
                GhosttyApp.shared.applyWindowBlurIfNeeded(window)
            } else {
                cmuxResetCompositorBackgroundBlur(on: window)
            }
        case .windowGlass:
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            cmuxResetCompositorBackgroundBlur(on: window)
            if let glass = plan.glass {
                didChangeGlassRoot = WindowGlassEffect.apply(
                    to: window,
                    tintColor: glass.tintColor,
                    style: glass.style
                )
            }
        }

        return WindowBackdropApplicationResult(
            didChangeGlassRoot: didChangeGlassRoot,
            usesWindowGlass: plan.usesWindowGlass
        )
    }

    static func updateGlassTint(to window: NSWindow, color: NSColor?) {
        WindowGlassEffect.updateTint(to: window, color: color)
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

private extension WindowBackdropPolicy {
    var identityComponent: String {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            return [
                "ghosttyTerminalBackdrop",
                color.hexString(includeAlpha: true),
                String(format: "%.4f", Double(opacity)),
                String(describing: renderingMode),
            ].joined(separator: ":")
        case let .sidebarMaterial(materialPolicy):
            return [
                "sidebarMaterial",
                String(describing: materialPolicy.material),
                String(describing: materialPolicy.blendingMode),
                String(describing: materialPolicy.state),
                String(format: "%.4f", materialPolicy.opacity),
                materialPolicy.tintColor.hexString(includeAlpha: true),
                String(format: "%.4f", Double(materialPolicy.cornerRadius)),
                String(materialPolicy.preferLiquidGlass),
                String(materialPolicy.usesWindowLevelGlass),
            ].joined(separator: ":")
        case .clear:
            return "clear"
        }
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

    static func currentFromUserDefaults(
        defaults: UserDefaults = .standard,
        app: GhosttyApp = .shared,
        colorScheme: ColorScheme? = nil
    ) -> Self {
        current(
            unifySurfaceBackdrops: defaults.object(forKey: "sidebarMatchTerminalBackground") as? Bool ?? false,
            colorScheme: colorScheme ?? currentAppColorScheme(),
            sidebarMaterial: defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.withinWindow.rawValue,
            sidebarState: defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue,
            sidebarTintHex: defaults.string(forKey: "sidebarTintHex") ?? SidebarTintDefaults.hex,
            sidebarTintHexLight: defaults.string(forKey: "sidebarTintHexLight"),
            sidebarTintHexDark: defaults.string(forKey: "sidebarTintHexDark"),
            sidebarTintOpacity: defaults.object(forKey: "sidebarTintOpacity") as? Double ?? SidebarTintDefaults.opacity,
            sidebarCornerRadius: defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0,
            sidebarBlurOpacity: defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 1.0,
            bgGlassEnabled: defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false,
            bgGlassTintHex: defaults.string(forKey: "bgGlassTintHex") ?? "#000000",
            bgGlassTintOpacity: defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03,
            app: app
        )
    }

    private static func currentAppColorScheme(
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
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

    func replacingTerminalBackgroundColor(_ color: NSColor) -> Self {
        Self(
            terminalBackgroundColor: color,
            terminalBackgroundOpacity: terminalBackgroundOpacity,
            terminalBackgroundBlur: terminalBackgroundBlur,
            terminalRenderingMode: terminalRenderingMode,
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: sidebarSettings,
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: windowGlassSettings.sidebarBlendModeRawValue,
                isEnabled: windowGlassSettings.isEnabled,
                tintHex: windowGlassSettings.tintHex,
                tintOpacity: windowGlassSettings.tintOpacity,
                terminalBackgroundBlur: terminalBackgroundBlur,
                terminalGlassTintColor: color.withAlphaComponent(terminalBackgroundOpacity)
            )
        )
    }

    var appKitWindowMutationID: String {
        backdropPlan().appKitMutationID
    }

    func shouldUseTransparentHosting(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        backdropPlan(glassEffectAvailable: glassEffectAvailable).usesTransparentWindow
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

    func backdropPlan(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> WindowBackdropPlan {
        let rootPolicy = terminalBackdropPolicy()
        let shouldApplyGlass = windowGlassSettings.shouldApply(glassEffectAvailable: glassEffectAvailable)
        if shouldApplyGlass {
            return WindowBackdropPlan(
                hostingPhase: .windowGlass,
                windowBackgroundColor: cmuxTransparentWindowBaseColor(),
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: WindowBackdropGlassPlan(
                    tintColor: windowGlassSettings.tintColor,
                    style: windowGlassSettings.style
                ),
                shouldApplyGhosttyCompositorBlur: false
            )
        }

        if compositedTerminalBackgroundColor.alphaComponent < 0.999 {
            return WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: cmuxTransparentWindowBaseColor(),
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: !terminalBackgroundBlur.isMacOSGlassStyle
            )
        }

        return WindowBackdropPlan(
            hostingPhase: .opaqueWindowFill,
            windowBackgroundColor: compositedTerminalBackgroundColor,
            windowIsOpaque: compositedTerminalBackgroundColor.alphaComponent >= 0.999,
            rootPolicy: rootPolicy,
            glass: nil,
            shouldApplyGhosttyCompositorBlur: false
        )
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
