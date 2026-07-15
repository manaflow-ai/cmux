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
    case streamHeaderTimedOut
    case admissionDenied(code: UInt16)
}
