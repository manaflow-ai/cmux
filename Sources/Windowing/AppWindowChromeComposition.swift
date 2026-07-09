import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import SwiftUI

typealias SidebarMaterialOption = WindowChromeSidebarMaterialOption
typealias SidebarBlendModeOption = WindowChromeSidebarBlendModeOption
typealias SidebarStateOption = WindowChromeSidebarStateOption
typealias SidebarTintDefaults = WindowChromeSidebarTintDefaults
typealias SidebarPresetOption = WindowChromeSidebarPresetOption

@MainActor
struct AppWindowChromeComposition {
    let glassEffect: WindowGlassEffect
    let nativeTitlebarBackdropCoordinator: NativeTitlebarBackdropCoordinator

    init(fullscreenAuxiliaryWindows: (@MainActor @Sendable () -> [NSWindow])? = nil) {
        self.init(
            glassEffect: WindowGlassEffect(),
            fullscreenAuxiliaryWindows: fullscreenAuxiliaryWindows
        )
    }

    init(
        glassEffect: WindowGlassEffect,
        fullscreenAuxiliaryWindows: (@MainActor @Sendable () -> [NSWindow])? = nil
    ) {
        self.glassEffect = glassEffect
        let resolvedFullscreenAuxiliaryWindows: @MainActor @Sendable () -> [NSWindow] =
            fullscreenAuxiliaryWindows ?? { NSApp.windows }
        nativeTitlebarBackdropCoordinator = NativeTitlebarBackdropCoordinator(
            fullscreenAuxiliaryWindows: resolvedFullscreenAuxiliaryWindows
        )
    }

    /// Pure layout policy for the custom titlebar band (insets, fullscreen
    /// controls placement, content top padding).
    var titlebarLayout: WindowTitlebarLayout {
        WindowTitlebarLayout()
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

    @MainActor
    private static func currentAppColorScheme(
        appearance: NSAppearance? = nil
    ) -> ColorScheme {
        let resolved = appearance ?? NSApplication.shared.effectiveAppearance
        return resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
