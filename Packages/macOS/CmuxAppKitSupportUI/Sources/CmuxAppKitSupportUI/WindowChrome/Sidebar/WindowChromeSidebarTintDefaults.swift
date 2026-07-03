/// Legacy default sidebar tint values.
public struct WindowChromeSidebarTintDefaults: Sendable {
    /// Default (dark-mode) tint hex value.
    public let hex: String

    /// Default light-mode tint hex. The base `hex` (#000000) is a dark tint;
    /// applying it in light mode black-washes the light sidebar material, so
    /// light mode falls back to Linear's light chrome neutral instead.
    public let lightHex: String

    /// Default tint opacity.
    public let opacity: Double

    /// Creates sidebar tint defaults.
    public init(
        hex: String = "#000000",
        lightHex: String = "#F3F3F4",
        opacity: Double = 0.18
    ) {
        self.hex = hex
        self.lightHex = lightHex
        self.opacity = opacity
    }
}
