public import AppKit
public import CmuxWorkspaces
import ObjectiveC

/// Applies resolved backdrop plans to `NSWindow` instances.
@MainActor
public final class WindowBackdropController {
    private static var rootBackdropViewKey: UInt8 = 0
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
        case .opaqueRootBackdrop:
            didChangeGlassRoot = dependencies.glassEffect.remove(from: window)
            installRootBackdrop(policy: plan.rootPolicy, in: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = plan.windowIsOpaque
            dependencies.resetCompositorBackgroundBlur(windowNumber: window.windowNumber)
        case .transparentRootBackdrop:
            didChangeGlassRoot = dependencies.glassEffect.remove(from: window)
            removeRootBackdrop(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            if plan.shouldApplyGhosttyCompositorBlur {
                dependencies.applyGhosttyCompositorBlurIfNeeded(to: window)
            } else {
                dependencies.resetCompositorBackgroundBlur(windowNumber: window.windowNumber)
            }
        case .windowGlass:
            removeRootBackdrop(from: window)
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
    public func updateGlassTint(to window: NSWindow, color: NSColor?) {
        dependencies.glassEffect.updateTint(to: window, color: color)
    }

    private func installRootBackdrop(
        policy: WindowBackdropPolicy,
        in window: NSWindow
    ) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return
        }

        let backdropView = rootBackdropView(for: window) ?? WindowRootBackdropView(frame: themeFrame.bounds)
        backdropView.apply(policy: policy)
        guard backdropView.superview !== themeFrame else { return }

        backdropView.removeFromSuperview()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(backdropView, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
        ])
        objc_setAssociatedObject(
            window,
            &Self.rootBackdropViewKey,
            backdropView,
            .OBJC_ASSOCIATION_RETAIN
        )
    }

    private func removeRootBackdrop(from window: NSWindow) {
        rootBackdropView(for: window)?.removeFromSuperview()
        objc_setAssociatedObject(window, &Self.rootBackdropViewKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private func rootBackdropView(for window: NSWindow) -> WindowRootBackdropView? {
        objc_getAssociatedObject(window, &Self.rootBackdropViewKey) as? WindowRootBackdropView
    }
}
