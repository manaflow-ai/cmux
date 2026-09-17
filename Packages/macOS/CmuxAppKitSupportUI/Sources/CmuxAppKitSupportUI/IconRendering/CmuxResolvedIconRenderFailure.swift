/// Describes why an appearance-resolved icon render did not produce a usable image.
public enum CmuxResolvedIconRenderFailure: Error, Equatable {
    /// The requested icon source could not be found or the requested size was invalid.
    case sourceUnavailable
    /// The source resolved, but drawing it produced no visible pixels.
    case blankOutput
}
