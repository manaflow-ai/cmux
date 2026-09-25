import Foundation

/// Immutable snapshot of the user's Sleepy Mode preferences, read fresh each
/// frame by the renderer so settings changes preview live.
public struct SleepyModeConfig: Equatable, Sendable {
    /// Mascot/scene color theme.
    public var theme: SleepyTheme = .cmux
    /// Which mascot/face to draw.
    public var mascot: SleepyMascot = .cmux
    /// Background glow gradient.
    public var glow: SleepyGlow = .black
    /// Whether the moon is drawn.
    public var showMoon = true
    /// Whether twinkling stars are drawn.
    public var showStars = true
    /// Whether floating "z z z" are drawn.
    public var showZs = true
    /// Whether the pixel clock and date are drawn.
    public var showClock = true
    /// Whether the battery and Wi-Fi status are drawn.
    public var showStatus = true
    /// Whether one walking pet per running agent is drawn.
    public var showPets = true

    // Default custom colors below are matched to the cmux theme so "Custom"
    // starts familiar; "RRGGBB" hex.

    /// Custom face color ("RRGGBB"), used when `theme == .custom`.
    public var customFace = "E0EDFF"
    /// Custom nightcap color ("RRGGBB"), used when `theme == .custom`.
    public var customCap = "5CD6FF"
    /// Custom blush color ("RRGGBB"), used when `theme == .custom`.
    public var customBlush = "FF99B5"
    /// Custom eye/ink color ("RRGGBB"), used when `theme == .custom`.
    public var customInk = "333D6B"
    /// Custom logo color ("RRGGBB"), used when `theme == .custom`.
    public var customLogo = "6BDEFF"
    /// Custom background color ("RRGGBB"), used when `glow == .custom`.
    public var customBackground = "060812"

    /// Creates a config with the default Sleepy Mode appearance.
    public init() {}
}
