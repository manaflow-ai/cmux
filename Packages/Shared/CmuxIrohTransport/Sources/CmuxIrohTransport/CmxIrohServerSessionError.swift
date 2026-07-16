/// Server-side connection framing and lifecycle failures.
public enum CmxIrohServerSessionError: Error, Equatable, Sendable {
    case alreadyAdmitted
    case notAdmitted
    case alreadyClosed
    case unexpectedEndOfStream
    case invalidAdmissionFrame
    case invalidFirstLane
    case invalidPeerLane
    case invalidServerLane
    case applicationLanesUnavailable
    /// One accepted application stream failed framing or lane validation.
    /// The stream was reset, but the admitted QUIC session remains usable.
    case applicationLaneRejected
    case streamHeaderTimedOut
    case admissionDenied(code: UInt16)
}
