public import CmuxLink

/// The body of a signal, typed per kind (`families/signal.schema.json`).
public enum SignalPayload: Sendable, Hashable {
    /// `carrier` is `.webrtc` (V1, B2) or `.webrtcWireGuard` (V2, B3); the
    /// host routes the offer to that carrier's acceptor.
    case offer(sdp: String, iceRestart: Bool, carrier: CarrierKind, auth: SignalAuth?)
    case answer(sdp: String, auth: SignalAuth?)
    case ice(ICECandidateInit)
    case iceEnd
    case bye(SignalByeReason)
}
