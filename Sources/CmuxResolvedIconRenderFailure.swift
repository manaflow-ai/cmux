/// Describes why an icon request did not produce visible pixels.
enum CmuxResolvedIconRenderFailure: Error, Equatable {
    /// Every candidate source was unavailable or the requested size was invalid.
    case sourceUnavailable
    /// A source resolved, but its draw pass contained no visible pixels.
    case blankOutput
}
