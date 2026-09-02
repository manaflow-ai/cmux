public import AppKit
public import CmuxWorkspaces
import ObjectiveC

/// Applies resolved backdrop plans to `NSWindow` instances.
@MainActor
public final class WindowBackdropController {
    private static var rootBackdropViewKey: UInt8 = 0
    private let dependencies: any WindowBackdropControllerDependencies
    private let contentOverlayTargetResolver: WindowContentOverlayTargetResolver

    /// Creates a controller with app-provided side-effect dependencies.
    public init(dependencies: any WindowBackdropControllerDependencies) {
        self.dependencies = dependencies
        contentOverlayTargetResolver = WindowContentOverlayTargetResolver(
            glassEffect: dependencies.glassEffect
        )
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
        case .opaqueRootBackdrop:
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
        installRootBackdrop(
            policy: plan.rootPolicy,
            hostingPhase: plan.hostingPhase,
            in: window
        )

        return WindowBackdropApplicationResult(
            didChangeGlassRoot: didChangeGlassRoot,
            usesWindowGlass: plan.usesWindowGlass
        )
    }

    /// Updates the glass tint for a window.
    public func updateGlassTint(to window: NSWindow, color: NSColor?) {
        dependencies.glassEffect.updateTint(to: window, color: color)
    }

    /// Updates the window-coordinate pane rectangles excluded from the shared root.
    ///
    /// - Parameters:
    ///   - rects: Visible pane rectangles whose local fill replaces the shared root.
    ///   - window: Window whose root backdrop owns the exclusion mask.
    public func updateRootBackdropExclusions(
        _ rects: [NSRect],
        in window: NSWindow
    ) {
        let backdropView = rootBackdropView(for: window)
        if let target = contentOverlayTargetResolver.installationTarget(for: window) {
            backdropView.install(in: target)
        }
        backdropView.updateExclusionRectsInWindow(rects)
    }

    private func installRootBackdrop(
        policy: WindowBackdropPolicy,
        hostingPhase: WindowBackdropHostingPhase,
        in window: NSWindow
    ) {
        guard let target = contentOverlayTargetResolver.installationTarget(for: window) else { return }
        let backdropView = rootBackdropView(for: window)
        backdropView.install(in: target)
        backdropView.apply(policy: policy, hostingPhase: hostingPhase)
    }

    private func rootBackdropView(for window: NSWindow) -> WindowRootBackdropView {
        if let existing = objc_getAssociatedObject(
            window,
            &Self.rootBackdropViewKey
        ) as? WindowRootBackdropView {
            return existing
        }

        let backdropView = WindowRootBackdropView(frame: .zero)
        objc_setAssociatedObject(
            window,
            &Self.rootBackdropViewKey,
            backdropView,
            .OBJC_ASSOCIATION_RETAIN
        )
        return backdropView
    }
}
