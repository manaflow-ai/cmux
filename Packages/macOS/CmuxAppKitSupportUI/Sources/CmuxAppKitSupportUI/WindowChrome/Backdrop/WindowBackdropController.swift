public import AppKit
public import CmuxWorkspaces

/// Applies resolved backdrop plans to `NSWindow` instances.
@MainActor
public final class WindowBackdropController {
    private let dependencies: any WindowBackdropControllerDependencies

    /// Creates a controller with app-provided side-effect dependencies.
    public init(dependencies: any WindowBackdropControllerDependencies) {
        self.dependencies = dependencies
    }

    /// Resolves and applies a snapshot to a window.
    public func apply(
        snapshot: WindowAppearanceSnapshot,
        to window: NSWindow,
        windowBackgroundPolicy: WindowBackgroundPolicy
    ) -> WindowBackdropApplicationResult {
        apply(
            plan: snapshot.backdropPlan(
                glassEffectAvailable: dependencies.glassEffect.isAvailable,
                windowBackgroundPolicy: windowBackgroundPolicy
            ),
            to: window
        )
    }

    /// Applies a precomputed plan to a window.
    public func apply(
        plan: WindowBackdropPlan,
        to window: NSWindow
    ) -> WindowBackdropApplicationResult {
        let didChangeGlassRoot: Bool

        switch plan.hostingPhase {
        case .opaqueWindowFill:
            didChangeGlassRoot = dependencies.glassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = plan.windowIsOpaque
            dependencies.resetCompositorBackgroundBlur(windowNumber: window.windowNumber)
        case .transparentRootBackdrop:
            didChangeGlassRoot = dependencies.glassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            if plan.shouldApplyGhosttyCompositorBlur {
                dependencies.applyGhosttyCompositorBlurIfNeeded(to: window)
            } else {
                dependencies.resetCompositorBackgroundBlur(windowNumber: window.windowNumber)
            }
        case .windowGlass:
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            dependencies.resetCompositorBackgroundBlur(windowNumber: window.windowNumber)
            if let glass = plan.glass {
                didChangeGlassRoot = dependencies.glassEffect.apply(
                    to: window,
                    tintColor: glass.tintColor,
                    style: glass.style
                )
            } else {
                didChangeGlassRoot = dependencies.glassEffect.remove(from: window)
            }
        }

        return WindowBackdropApplicationResult(
            didChangeGlassRoot: didChangeGlassRoot,
            usesWindowGlass: plan.usesWindowGlass
        )
    }

    /// Updates the glass tint for a window.
    ///
    /// - Parameters:
    ///   - window: Window whose glass root should receive the tint update.
    ///   - snapshot: Appearance snapshot used to resolve the active glass plan.
    ///   - windowBackgroundPolicy: Window background settings used for non-terminal glass.
    ///   - suppressNativeTerminalGlassTint: Whether native Ghostty glass styles should omit terminal tint.
    public func updateGlassTint(
        to window: NSWindow,
        snapshot: WindowAppearanceSnapshot,
        windowBackgroundPolicy: WindowBackgroundPolicy,
        suppressNativeTerminalGlassTint: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    ) {
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: dependencies.glassEffect.isAvailable,
            windowBackgroundPolicy: windowBackgroundPolicy,
            suppressNativeTerminalGlassTint: suppressNativeTerminalGlassTint
        )
        updateGlassTint(to: window, color: plan.glass?.tintColor)
    }

    /// Updates the glass tint for a window with an already-resolved color.
    public func updateGlassTint(to window: NSWindow, color: NSColor?) {
        dependencies.glassEffect.updateTint(to: window, color: color)
    }
}
