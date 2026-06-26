public import AppKit
public import SwiftUI
public import CmuxFoundation
public import CmuxWorkspaces

/// Resolved window chrome appearance for a single render pass.
public struct WindowAppearanceSnapshot {
    /// Current terminal background color.
    public let terminalBackgroundColor: NSColor

    /// Current terminal background opacity.
    public let terminalBackgroundOpacity: CGFloat

    /// Current terminal background blur.
    public let terminalBackgroundBlur: GhosttyBackgroundBlur

    /// Current terminal backdrop rendering owner.
    public let terminalRenderingMode: GhosttyTerminalBackdropRenderingMode

    /// Whether sidebars share the terminal root backdrop.
    public let unifySurfaceBackdrops: Bool

    /// Resolved sidebar backdrop settings.
    public let sidebarSettings: SidebarBackdropSettingsSnapshot

    /// Resolved window glass settings.
    public let windowGlassSettings: WindowGlassSettingsSnapshot

    /// Creates a resolved window appearance snapshot.
    public init(
        terminalBackgroundColor: NSColor,
        terminalBackgroundOpacity: CGFloat,
        terminalBackgroundBlur: GhosttyBackgroundBlur,
        terminalRenderingMode: GhosttyTerminalBackdropRenderingMode,
        unifySurfaceBackdrops: Bool,
        sidebarSettings: SidebarBackdropSettingsSnapshot,
        windowGlassSettings: WindowGlassSettingsSnapshot
    ) {
        self.terminalBackgroundColor = terminalBackgroundColor
        self.terminalBackgroundOpacity = terminalBackgroundOpacity
        self.terminalBackgroundBlur = terminalBackgroundBlur
        self.terminalRenderingMode = terminalRenderingMode
        self.unifySurfaceBackdrops = unifySurfaceBackdrops
        self.sidebarSettings = sidebarSettings
        self.windowGlassSettings = windowGlassSettings
    }

    /// Clamps opacity into the visible `0...1` range.
    public static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    /// Returns `backgroundColor` composited over `baseColor` with the given opacity.
    public static func compositedTerminalColor(
        backgroundColor: NSColor,
        opacity: Double,
        over baseColor: NSColor = .windowBackgroundColor
    ) -> NSColor {
        WindowChromeColorResolver().compositedColor(
            backgroundColor.withAlphaComponent(clampedOpacity(opacity)),
            over: baseColor
        )
    }

    /// Returns the terminal backdrop rendering mode.
    public static func terminalRenderingMode(
        usesHostLayerBackground: Bool
    ) -> GhosttyTerminalBackdropRenderingMode {
        usesHostLayerBackground ? .windowHostBackdrop : .ghosttyRendererOwnedBackgroundImage
    }

    /// Terminal background composited over the window background.
    public var compositedTerminalBackgroundColor: NSColor {
        Self.compositedTerminalColor(
            backgroundColor: terminalBackgroundColor,
            opacity: Double(terminalBackgroundOpacity)
        )
    }

    /// Color scheme readable against the chrome background.
    public var chromeColorScheme: ColorScheme {
        WindowChromeColorResolver().readableColorScheme(for: compositedTerminalBackgroundColor)
    }

    /// Color scheme used for sidebar content.
    public var sidebarContentColorScheme: ColorScheme {
        unifySurfaceBackdrops ? chromeColorScheme : sidebarSettings.colorScheme
    }

    /// Returns the backdrop policy for one chrome role.
    public func policy(for role: WindowBackdropRole) -> WindowBackdropPolicy {
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

    /// Returns the root terminal backdrop policy.
    public func terminalBackdropPolicy() -> WindowBackdropPolicy {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return .clear
        }
        return .ghosttyTerminalBackdrop(
            color: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity,
            renderingMode: terminalRenderingMode
        )
    }

    /// Whether AppKit hosting must be transparent for this snapshot.
    public func shouldUseTransparentHosting(
        glassEffectAvailable: Bool,
        windowBackgroundPolicy: WindowBackgroundPolicy
    ) -> Bool {
        backdropPlan(
            glassEffectAvailable: glassEffectAvailable,
            windowBackgroundPolicy: windowBackgroundPolicy
        ).usesTransparentWindow
    }

    /// Returns the AppKit window mutation plan for this snapshot.
    ///
    /// - Parameters:
    ///   - glassEffectAvailable: Whether native `NSGlassEffectView` is available.
    ///   - windowBackgroundPolicy: Window background settings used for non-terminal glass.
    ///   - suppressNativeTerminalGlassTint: Whether native Ghostty glass styles should omit terminal tint.
    public func backdropPlan(
        glassEffectAvailable: Bool,
        windowBackgroundPolicy: WindowBackgroundPolicy,
        suppressNativeTerminalGlassTint: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    ) -> WindowBackdropPlan {
        let rootPolicy = terminalBackdropPolicy()
        if windowGlassSettings.shouldApply(
            glassEffectAvailable: glassEffectAvailable,
            windowBackgroundPolicy: windowBackgroundPolicy
        ) {
            return WindowBackdropPlan(
                hostingPhase: .windowGlass,
                windowBackgroundColor: windowBackgroundPolicy.transparentWindowBaseColor,
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: WindowBackdropGlassPlan(
                    tintColor: windowGlassSettings.resolvedTintColor(
                        glassEffectAvailable: glassEffectAvailable,
                        suppressNativeTerminalGlassTint: suppressNativeTerminalGlassTint
                    ),
                    style: windowGlassSettings.style
                ),
                shouldApplyGhosttyCompositorBlur: false
            )
        }

        if terminalBackgroundOpacity < 0.999 {
            return WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: windowBackgroundPolicy.transparentWindowBaseColor,
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: !terminalBackgroundBlur.isMacOSGlassStyle
            )
        }

        return WindowBackdropPlan(
            hostingPhase: .opaqueWindowFill,
            windowBackgroundColor: compositedTerminalBackgroundColor,
            windowIsOpaque: true,
            rootPolicy: rootPolicy,
            glass: nil,
            shouldApplyGhosttyCompositorBlur: false
        )
    }

    /// Returns the window root backdrop resolution for a pane-local surface color.
    public func windowRootBackdropResolution(surfaceBackgroundColor color: NSColor?) -> WindowRootBackdropResolution {
        WindowRootBackdropResolution(
            snapshot: self,
            source: color == nil ? "defaultBackground" : "defaultBackground(surfaceOverrideLocal)",
            overrideHex: color?.hexString() ?? "nil"
        )
    }

    /// Stable identity for AppKit window mutations.
    public func appKitWindowMutationID(windowBackgroundPolicy: WindowBackgroundPolicy) -> String {
        backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: windowBackgroundPolicy
        ).appKitMutationID
    }
}
