public import AppKit
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

    /// Creates a terminal appearance snapshot.
    public init(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        usesHostLayerBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.usesHostLayerBackground = usesHostLayerBackground
    }
}
