/// Legacy default sidebar tint values.
public struct WindowChromeSidebarTintDefaults: Sendable {
    /// Default tint hex value.
    public let hex: String

    /// Default tint opacity.
    public let opacity: Double

    /// Whether the sidebar uses the terminal background instead of the tint
    /// when the user has not chosen. Mirrors the
    /// `sidebarAppearance.matchTerminalBackground` catalog default.
    public static let matchesTerminalBackground = false

    /// What light mode uses while the stock tint is in place. The stock
    /// #393939 is a dark glass and light mode turns the sidebar text dark,
    /// so it gets the mirror: a light glass at the same strength. (Main's
    /// light #000000 at 18% assumed a light material under it; the
    /// compositor ground is the raw desktop blur, often dark.)
    public static let light = WindowChromeSidebarTintDefaults(hex: "#F2F2F2", opacity: 0.72)

    /// Creates sidebar tint defaults.
    public init(
        hex: String = "#393939",
        opacity: Double = 0.72
    ) {
        self.hex = hex
        self.opacity = opacity
    }
}
