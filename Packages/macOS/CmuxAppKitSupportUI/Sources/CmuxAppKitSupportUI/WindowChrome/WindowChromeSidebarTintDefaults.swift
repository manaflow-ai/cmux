/// Legacy default sidebar tint values.
public struct WindowChromeSidebarTintDefaults: Sendable {
    /// Default tint hex value.
    public let hex: String

    /// Default tint opacity.
    public let opacity: Double

    /// Creates sidebar tint defaults.
    public init(
        hex: String = "#000000",
        opacity: Double = 0.18
    ) {
        self.hex = hex
        self.opacity = opacity
    }
}
