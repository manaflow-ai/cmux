/// One WebRTC signaling message for one session, as the relay carries it
/// (a0-rpc.md section 5.12, `signal`). `from` is set by the relay to the
/// sender's authenticated install; a sender never sets it.
public struct SignalMessage: Sendable, Hashable {
    public var session: String
    public var to: String
    public var from: String?
    public var payload: SignalPayload

    public init(session: String, to: String, from: String? = nil, payload: SignalPayload) {
        self.session = session
        self.to = to
        self.from = from
        self.payload = payload
    }
}
