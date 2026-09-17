import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces

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
