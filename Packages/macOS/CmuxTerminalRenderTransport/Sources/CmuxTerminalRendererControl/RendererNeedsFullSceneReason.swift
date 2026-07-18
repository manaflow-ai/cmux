/// The reason a worker cannot apply the next semantic delta safely.
public enum RendererNeedsFullSceneReason: UInt32, Sendable {
    /// The presentation has not received an initial full scene.
    case initialSceneRequired = 1

    /// A canonical or presentation sequence was not available.
    case sequenceGap = 2

    /// Ghostty rejected or could not decode the opaque scene bytes.
    case decodeFailure = 3

    /// Presentation state changed and invalidated the previous scene base.
    case presentationReset = 4
}
