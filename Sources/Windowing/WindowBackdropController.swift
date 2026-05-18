import AppKit
import SwiftUI

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
            } else {
                didChangeGlassRoot = WindowGlassEffect.remove(from: window)
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

extension WindowAppearanceSnapshot {
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

    func backdropPlan(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> WindowBackdropPlan {
        let rootPolicy = terminalBackdropPolicy()
        if windowGlassSettings.shouldApply(glassEffectAvailable: glassEffectAvailable) {
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

    private static func currentAppColorScheme(
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
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
