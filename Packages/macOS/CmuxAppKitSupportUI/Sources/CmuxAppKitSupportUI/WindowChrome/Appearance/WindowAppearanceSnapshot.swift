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

    /// The single light/dark decision used by window, Dock, and sidebar chrome.
    ///
    /// This is captured from the resolved terminal theme rather than from
    /// AppKit's ambient appearance. Keeping it in the snapshot makes every
    /// dependent surface consume the same answer for a render pass.
    public let resolvedColorScheme: ColorScheme

    /// Creates a resolved window appearance snapshot.
    public init(
        terminalBackgroundColor: NSColor,
        terminalBackgroundOpacity: CGFloat,
        terminalBackgroundBlur: GhosttyBackgroundBlur,
        terminalRenderingMode: GhosttyTerminalBackdropRenderingMode,
        unifySurfaceBackdrops: Bool,
        sidebarSettings: SidebarBackdropSettingsSnapshot,
        windowGlassSettings: WindowGlassSettingsSnapshot,
        resolvedColorScheme: ColorScheme? = nil
    ) {
        let resolvedScheme = resolvedColorScheme ?? Self.colorScheme(
            forTerminalBackgroundColor: terminalBackgroundColor,
            opacity: Double(Self.clampedOpacity(Double(terminalBackgroundOpacity)))
        )
        self.terminalBackgroundColor = terminalBackgroundColor
        self.terminalBackgroundOpacity = terminalBackgroundOpacity
        self.terminalBackgroundBlur = terminalBackgroundBlur
        self.terminalRenderingMode = terminalRenderingMode
        self.unifySurfaceBackdrops = unifySurfaceBackdrops
        self.sidebarSettings = SidebarBackdropSettingsSnapshot(
            materialRawValue: sidebarSettings.materialRawValue,
            blendModeRawValue: sidebarSettings.blendModeRawValue,
            stateRawValue: sidebarSettings.stateRawValue,
            tintHex: sidebarSettings.tintHex,
            tintHexLight: sidebarSettings.tintHexLight,
            tintHexDark: sidebarSettings.tintHexDark,
            tintOpacity: sidebarSettings.tintOpacity,
            cornerRadius: sidebarSettings.cornerRadius,
            blurOpacity: sidebarSettings.blurOpacity,
            colorScheme: resolvedScheme
        )
        self.windowGlassSettings = windowGlassSettings
        self.resolvedColorScheme = resolvedScheme
    }

    /// Clamps opacity into the visible `0...1` range.
    public static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    /// Resolves the light/dark decision for the rendered terminal backdrop.
    public static func colorScheme(
        forTerminalBackgroundColor backgroundColor: NSColor,
        opacity: Double
    ) -> ColorScheme {
        WindowChromeColorResolver().readableColorScheme(
            for: compositedTerminalColor(
                backgroundColor: backgroundColor,
                opacity: opacity
            )
        )
    }

    /// Resolves the light/dark decision chrome should render with over the
    /// terminal backdrop.
    ///
    /// An opaque terminal theme owns its rendered pixels, so the theme's own
    /// scheme stays authoritative even when the window appearance disagrees.
    /// A translucent theme composites over the window base painted by the
    /// ambient appearance, so the readable answer must come from that rendered
    /// result — otherwise a translucent dark theme in a light window keys
    /// white chrome icons onto a visibly light backdrop.
    public static func resolvedChromeColorScheme(
        terminalScheme: ColorScheme?,
        backgroundColor: NSColor,
        opacity: Double,
        ambientScheme: ColorScheme
    ) -> ColorScheme {
        let clamped = Double(clampedOpacity(opacity))
        if clamped >= 0.999 {
            if let terminalScheme { return terminalScheme }
            return WindowChromeColorResolver().readableColorScheme(for: backgroundColor)
        }
        let composited = compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: clamped,
            over: resolvedColor(.windowBackgroundColor, for: ambientScheme)
        )
        return WindowChromeColorResolver().readableColorScheme(for: composited)
    }

    /// Returns the concrete AppKit appearance matching a resolved scheme.
    ///
    /// AppKit semantic colors resolve against a view's effective appearance;
    /// callers hosting native subtrees should assign this appearance at their
    /// root instead of allowing each descendant to consult the window cascade.
    public static func appKitAppearance(for colorScheme: ColorScheme) -> NSAppearance {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance(named: .aqua)!
    }

    /// Resolves an AppKit semantic color against a concrete cmux scheme.
    /// AppKit does not expose UIKit's `resolvedColor(with:)`; resolving under
    /// `performAsCurrentDrawingAppearance` is the supported way to snapshot a
    /// dynamic `NSColor` for a detached/native hosting subtree.
    public static func resolvedColor(
        _ color: NSColor,
        for colorScheme: ColorScheme
    ) -> NSColor {
        let appearance = appKitAppearance(for: colorScheme)
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// Composites a terminal background over the concrete window base for a
    /// resolved cmux scheme. Native chrome should use this instead of the
    /// ambient ``NSColor.windowBackgroundColor`` when the system appearance
    /// and terminal theme intentionally differ.
    public static func resolvedChromeBackgroundColor(
        backgroundColor: NSColor,
        opacity: Double,
        colorScheme: ColorScheme
    ) -> NSColor {
        let baseColor = resolvedColor(.windowBackgroundColor, for: colorScheme)
        return compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: opacity,
            over: baseColor
        )
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
            opacity: Double(Self.clampedOpacity(Double(terminalBackgroundOpacity)))
        )
    }

    /// Terminal background composited over a concrete light/dark window base.
    ///
    /// This is for chrome surfaces that must follow the resolved terminal theme
    /// even when the host window's ambient appearance disagrees. The ordinary
    /// ``compositedTerminalBackgroundColor`` remains the actual window-backdrop
    /// calculation; this value is the stable color input for Dock/Bonsplit
    /// chrome and other detached native surfaces.
    public var resolvedChromeBackgroundColor: NSColor {
        Self.resolvedChromeBackgroundColor(
            backgroundColor: terminalBackgroundColor,
            opacity: Double(Self.clampedOpacity(Double(terminalBackgroundOpacity))),
            colorScheme: resolvedColorScheme
        )
    }

    /// Color scheme readable against the chrome background.
    public var chromeColorScheme: ColorScheme {
        resolvedColorScheme
    }

    /// Color scheme used for sidebar content and Dock chrome.
    public var sidebarContentColorScheme: ColorScheme {
        resolvedColorScheme
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
    public func backdropPlan(
        glassEffectAvailable: Bool,
        windowBackgroundPolicy: WindowBackgroundPolicy
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
                    tintColor: windowGlassSettings.tintColor,
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
