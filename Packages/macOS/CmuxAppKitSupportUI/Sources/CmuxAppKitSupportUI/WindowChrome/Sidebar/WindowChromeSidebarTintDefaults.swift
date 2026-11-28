/// Legacy default sidebar tint values.
public struct WindowChromeSidebarTintDefaults: Sendable {
    /// Default tint hex value.
    public let hex: String

    /// Default tint opacity.
    public let opacity: Double

    /// Whether the sidebar uses the terminal background instead of the tint
    /// when the user has not chosen. Mirrors the
    /// `sidebarAppearance.matchTerminalBackground` catalog default.
    public static let matchesTerminalBackground = true

    /// Creates sidebar tint defaults.
    public init(
        hex: String = "#000000",
        opacity: Double = 0.18
    ) {
        self.hex = hex
        self.opacity = opacity
    }
}
