/// A live appearance slider that can be peeked as a floating control.
public enum AppearanceTuningAxis: String, CaseIterable, Identifiable, Sendable {
    /// How much of the desktop or painting shows through the tint.
    case glassTransparency
    /// The theme tint's hue shift.
    case hue
    /// The theme tint's saturation multiplier.
    case saturation

    public var id: String { rawValue }
}
