public import AppKit
public import SwiftUI
public import CmuxFoundation

/// Current terminal appearance values needed by window chrome policy.
public struct WindowTerminalAppearanceSnapshot {
    /// Current default terminal background color.
    public let backgroundColor: NSColor

    /// Current default terminal background opacity.
    public let backgroundOpacity: Double

    /// Current default terminal background blur.
    public let backgroundBlur: GhosttyBackgroundBlur

    /// Whether terminal host layers own background fills.
    public let usesHostLayerBackground: Bool

    /// The light/dark scheme selected by the resolved terminal theme.
    ///
    /// This is captured at the composition boundary so window chrome does not
    /// need to infer a second answer from AppKit's ambient appearance. The
    /// optional initializer argument keeps older callers source-compatible;
    /// callers that do not have the terminal preference fall back to the
    /// rendered background's readable scheme.
    public let resolvedColorScheme: ColorScheme?

    /// Creates a terminal appearance snapshot.
    public init(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        usesHostLayerBackground: Bool,
        resolvedColorScheme: ColorScheme? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.usesHostLayerBackground = usesHostLayerBackground
        self.resolvedColorScheme = resolvedColorScheme
    }
}
