/// Whether a background control connection can be retried without a new
/// authority or route edge.
enum SecondaryClientAttempt {
    case connected(SecondaryClientHandle)
    /// The route was authorized and compatible, but the network exchange failed.
    case transientFailure
    /// The saved route, authenticated identity, or host response is incompatible.
    case permanentFailure
}
