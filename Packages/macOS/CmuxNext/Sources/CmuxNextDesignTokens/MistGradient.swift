public import CmuxTheme
/// The axis on which a mist scrim fades the artwork into the theme surface.
public nonisolated enum MistGradientAxis: String, Equatable, Sendable {
    case vertical
}

/// One color stop in a ``MistGradient``.
public nonisolated struct MistGradientStop: Equatable, Sendable {
    /// A normalized location in the gradient, from 0 through 1.
    public let location: Double
    /// The scrim color at ``location``.
    public let color: ThemeRGB

    /// Creates a stop, clamping its location to the gradient's normalized range.
    ///
    /// - Parameters:
    ///   - location: The normalized stop location.
    ///   - color: The scrim color at that location.
    public init(location: Double, color: ThemeRGB) {
        self.location = min(max(location, 0), 1)
        self.color = color
    }
}

/// The art-to-surface scrim used by mist mode.
public nonisolated struct MistGradient: Equatable, Sendable {
    /// Mist follows the content's top-to-bottom reading axis.
    public let axis: MistGradientAxis
    /// Ordered stops, with the first stop at the art and the last at the
    /// theme surface.
    public let stops: [MistGradientStop]

    /// Creates an ordered gradient description.
    ///
    /// - Parameters:
    ///   - axis: The content axis along which to apply the scrim.
    ///   - stops: The stops to sort by normalized location.
    public init(axis: MistGradientAxis = .vertical, stops: [MistGradientStop]) {
        self.axis = axis
        self.stops = stops.sorted { $0.location < $1.location }
    }
}
