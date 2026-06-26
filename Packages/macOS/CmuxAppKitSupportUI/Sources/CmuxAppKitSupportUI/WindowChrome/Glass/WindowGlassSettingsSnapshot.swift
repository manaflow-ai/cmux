public import AppKit
public import CmuxFoundation
public import CmuxWorkspaces

/// Persisted and terminal-driven settings for the window-level glass root.
public struct WindowGlassSettingsSnapshot {
    /// Raw `sidebarBlendMode` value.
    public let sidebarBlendModeRawValue: String

    /// Whether background glass is explicitly enabled.
    public let isEnabled: Bool

    /// Glass tint hex value.
    public let tintHex: String

    /// Glass tint opacity.
    public let tintOpacity: Double

    /// Current Ghostty background blur mode.
    public let terminalBackgroundBlur: GhosttyBackgroundBlur

    /// Current terminal-derived glass tint, when a Ghostty glass mode owns it.
    public let terminalGlassTintColor: NSColor?

    /// Creates a window glass settings snapshot.
    public init(
        sidebarBlendModeRawValue: String,
        isEnabled: Bool,
        tintHex: String,
        tintOpacity: Double,
        terminalBackgroundBlur: GhosttyBackgroundBlur = .disabled,
        terminalGlassTintColor: NSColor? = nil
    ) {
        self.sidebarBlendModeRawValue = sidebarBlendModeRawValue
        self.isEnabled = isEnabled
        self.tintHex = tintHex
        self.tintOpacity = tintOpacity
        self.terminalBackgroundBlur = terminalBackgroundBlur
        self.terminalGlassTintColor = terminalGlassTintColor
    }

    /// Resolved tint color for window glass.
    public var tintColor: NSColor {
        if let terminalGlassTintColor, terminalBackgroundBlur.isMacOSGlassStyle {
            return terminalGlassTintColor
        }
        return (NSColor(hex: tintHex) ?? .black).withAlphaComponent(tintOpacity)
    }

    /// Resolved tint color for the AppKit glass effect.
    ///
    /// - Parameters:
    ///   - glassEffectAvailable: Whether the native `NSGlassEffectView` path is available.
    ///   - suppressNativeTerminalGlassTint: Whether native Ghostty glass styles should omit terminal tint.
    /// - Returns: The color to pass to AppKit, or `nil` to leave native glass untinted.
    public func resolvedTintColor(
        glassEffectAvailable: Bool,
        suppressNativeTerminalGlassTint: Bool
    ) -> NSColor? {
        if glassEffectAvailable,
           suppressNativeTerminalGlassTint,
           terminalBackgroundBlur.isMacOSGlassStyle {
            return nil
        }
        return tintColor
    }

    /// Native glass style for the current settings.
    public var style: WindowGlassEffectStyle {
        terminalBackgroundBlur.windowGlassStyle ?? .regular
    }

    /// Whether these settings request window glass.
    public func shouldApply(
        glassEffectAvailable: Bool,
        windowBackgroundPolicy: WindowBackgroundPolicy
    ) -> Bool {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return true
        }
        return windowBackgroundPolicy.shouldApplyWindowGlass(
            sidebarBlendMode: sidebarBlendModeRawValue,
            bgGlassEnabled: isEnabled,
            glassEffectAvailable: glassEffectAvailable
        )
    }

    /// Stable identity for AppKit mutations.
    public var appKitMutationID: String {
        [
            sidebarBlendModeRawValue,
            String(isEnabled),
            tintHex,
            String(format: "%.4f", tintOpacity),
            String(describing: terminalBackgroundBlur),
            terminalGlassTintColor?.hexString(includeAlpha: true) ?? "nil",
        ].joined(separator: "|")
    }
}
