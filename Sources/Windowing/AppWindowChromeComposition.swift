import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaceWindow
import SwiftUI

typealias SidebarMaterialOption = WindowChromeSidebarMaterialOption
typealias SidebarBlendModeOption = WindowChromeSidebarBlendModeOption
typealias SidebarStateOption = WindowChromeSidebarStateOption
typealias SidebarTintDefaults = WindowChromeSidebarTintDefaults
typealias SidebarPresetOption = WindowChromeSidebarPresetOption

@MainActor
final class AppWindowBackdropControllerDependencies: WindowBackdropControllerDependencies {
    let glassEffect: any WindowGlassEffectManaging

    init(glassEffect: any WindowGlassEffectManaging) {
        self.glassEffect = glassEffect
    }

    func resetCompositorBackgroundBlur(windowNumber: Int) {
        WindowBackgroundComposition.blurController.resetBackgroundBlur(windowNumber: windowNumber)
    }

    func applyGhosttyCompositorBlurIfNeeded(to window: NSWindow) {
        GhosttyApp.shared.applyWindowBlurIfNeeded(window)
    }
}

@MainActor
struct AppWindowChromeComposition {
    let glassEffect: WindowGlassEffect
    let nativeTitlebarBackdropCoordinator: NativeTitlebarBackdropCoordinator

    init(fullscreenAuxiliaryWindows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
        self.init(
            glassEffect: WindowGlassEffect(),
            fullscreenAuxiliaryWindows: fullscreenAuxiliaryWindows
        )
    }

    init(
        glassEffect: WindowGlassEffect,
        fullscreenAuxiliaryWindows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }
    ) {
        self.glassEffect = glassEffect
        nativeTitlebarBackdropCoordinator = NativeTitlebarBackdropCoordinator(
            fullscreenAuxiliaryWindows: fullscreenAuxiliaryWindows
        )
    }

    var windowBackgroundPolicy: WindowBackgroundPolicy {
        WindowBackgroundComposition.policy
    }

    var backdropController: WindowBackdropController {
        WindowBackdropController(
            dependencies: AppWindowBackdropControllerDependencies(glassEffect: glassEffect)
        )
    }

    var contentOverlayTargetResolver: WindowContentOverlayTargetResolver {
        WindowContentOverlayTargetResolver(glassEffect: glassEffect)
    }

    func terminalAppearanceSnapshot(app: GhosttyApp = .shared) -> WindowTerminalAppearanceSnapshot {
        WindowTerminalAppearanceSnapshot(
            backgroundColor: app.defaultBackgroundColor,
            backgroundOpacity: app.defaultBackgroundOpacity,
            backgroundBlur: app.defaultBackgroundBlur,
            usesHostLayerBackground: app.usesHostLayerBackground
        )
    }

    func appearanceResolver(app: GhosttyApp = .shared) -> WindowAppearanceResolver {
        WindowAppearanceResolver(terminalAppearance: terminalAppearanceSnapshot(app: app))
    }

    func appearanceSnapshot(
        settings: WindowAppearanceUserSettingsSnapshot,
        app: GhosttyApp = .shared
    ) -> WindowAppearanceSnapshot {
        appearanceResolver(app: app).current(settings: settings)
    }

    func appearanceSnapshotFromUserDefaults(
        defaults: UserDefaults = .standard,
        app: GhosttyApp = .shared,
        colorScheme: ColorScheme? = nil
    ) -> WindowAppearanceSnapshot {
        appearanceResolver(app: app).currentFromUserDefaults(
            defaults: defaults,
            colorScheme: colorScheme ?? Self.currentAppColorScheme()
        )
    }

    private static func currentAppColorScheme(
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
