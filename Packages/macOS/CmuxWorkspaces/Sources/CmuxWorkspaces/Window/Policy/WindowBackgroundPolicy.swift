public import AppKit

/// Decides whether the workspace window uses a transparent/glass background.
///
/// Lifted faithfully from the `cmuxShouldApplyWindowGlass` /
/// `cmuxShouldUseTransparentBackgroundWindow` / `cmuxShouldUseClearWindowBackground`
/// free functions in the terminal god file. The decisions are pure: glass
/// availability is supplied by the caller (the app passes
/// `WindowGlassEffect.isAvailable`, whose underlying `NSGlassEffectView`
/// lifecycle stays app-side), and the two persisted settings are read through
/// the injected ``WindowBackgroundSettingsReading`` seam instead of
/// `UserDefaults.standard`.
public struct WindowBackgroundPolicy: Sendable {
    private let settings: any WindowBackgroundSettingsReading

    /// Creates a policy reading from the injected settings seam.
    public init(settings: any WindowBackgroundSettingsReading) {
        self.settings = settings
    }

    /// Whether the native window-glass treatment should be applied.
    ///
    /// Native `NSGlassEffectView` vs `NSVisualEffectView` fallback is chosen
    /// inside the app's `WindowGlassEffect.apply`; user settings alone decide
    /// whether glass is on. `glassEffectAvailable` is accepted to preserve the
    /// original signature but does not influence the decision, matching legacy.
    public func shouldApplyWindowGlass(
        sidebarBlendMode: String,
        bgGlassEnabled: Bool,
        glassEffectAvailable _: Bool
    ) -> Bool {
        sidebarBlendMode == "behindWindow" && bgGlassEnabled
    }

    /// Whether the window itself should use a transparent (glass) background,
    /// derived from the injected settings.
    public func shouldUseTransparentBackgroundWindow(glassEffectAvailable: Bool) -> Bool {
        shouldApplyWindowGlass(
            sidebarBlendMode: settings.sidebarBlendModeRawValue,
            bgGlassEnabled: settings.isBackgroundGlassEnabled,
            glassEffectAvailable: glassEffectAvailable
        )
    }

    /// Whether the window background should be cleared for the given terminal
    /// opacity and Ghostty glass style.
    public func shouldUseClearWindowBackground(
        for opacity: Double,
        usesGhosttyGlassStyle: Bool = false,
        glassEffectAvailable: Bool
    ) -> Bool {
        shouldUseTransparentBackgroundWindow(glassEffectAvailable: glassEffectAvailable)
            || usesGhosttyGlassStyle
            || opacity < 0.999
    }

    /// The base color for a transparent window.
    ///
    /// A tiny non-zero alpha matches Ghostty's window compositing behavior on
    /// macOS and avoids visual artifacts that can happen with a fully clear
    /// window background.
    public var transparentWindowBaseColor: NSColor {
        NSColor.white.withAlphaComponent(0.001)
    }
}
