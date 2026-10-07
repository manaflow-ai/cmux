/// The body of a signal, typed per kind (`families/signal.schema.json`).
public enum SignalPayload: Sendable, Hashable {
    case offer(sdp: String, iceRestart: Bool, auth: SignalAuth?)
    case answer(sdp: String, auth: SignalAuth?)
    case ice(ICECandidateInit)
    case iceEnd
    case bye(SignalByeReason)
}
