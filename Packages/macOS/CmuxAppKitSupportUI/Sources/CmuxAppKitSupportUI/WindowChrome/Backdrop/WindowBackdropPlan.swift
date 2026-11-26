public import AppKit
import CmuxFoundation

/// AppKit window mutation plan for a resolved backdrop.
public struct WindowBackdropPlan {
    /// Hosting phase to apply.
    public let hostingPhase: WindowBackdropHostingPhase

    /// Window background color.
    public let windowBackgroundColor: NSColor

    /// Whether the window should be opaque.
    public let windowIsOpaque: Bool

    /// Root backdrop policy.
    public let rootPolicy: WindowBackdropPolicy

    /// Glass plan, when `hostingPhase` is `.windowGlass`.
    public let glass: WindowBackdropGlassPlan?

    /// Whether Ghostty compositor blur should be applied.
    public let shouldApplyGhosttyCompositorBlur: Bool

    /// Creates a window backdrop plan.
    public init(
        hostingPhase: WindowBackdropHostingPhase,
        windowBackgroundColor: NSColor,
        windowIsOpaque: Bool,
        rootPolicy: WindowBackdropPolicy,
        glass: WindowBackdropGlassPlan?,
        shouldApplyGhosttyCompositorBlur: Bool
    ) {
        self.hostingPhase = hostingPhase
        self.windowBackgroundColor = windowBackgroundColor
        self.windowIsOpaque = windowIsOpaque
        self.rootPolicy = rootPolicy
        self.glass = glass
        self.shouldApplyGhosttyCompositorBlur = shouldApplyGhosttyCompositorBlur
    }

    /// Whether the window should be transparent.
    public var usesTransparentWindow: Bool {
        hostingPhase != .opaqueWindowFill
    }

    /// Whether the plan uses window glass.
    public var usesWindowGlass: Bool {
        hostingPhase == .windowGlass
    }

    /// Stable identity for AppKit mutations.
    public var appKitMutationID: String {
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
