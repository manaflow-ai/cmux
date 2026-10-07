/// One `signal` frame relayed by `HostDO`, field for field: B2's signaling
/// on `CmuxControlPlane.SignalFrame` converts with a copy. `from` is set by
/// the relay to the sender's authenticated install, never by a client.
public struct SignalingMessage: Sendable, Hashable, Codable {
    public var kind: SignalingKind
    /// `sess_…`: one peer connection attempt.
    public var session: String
    public var to: String
    public var from: String?
    /// SDP (`sdp`, at most 65536 characters) or a candidate (`candidate`,
    /// `sdpMid`, `sdpMLineIndex`, at most 1024).
    public var body: [String: String]

    public init(kind: SignalingKind, session: String, to: String, from: String? = nil, body: [String: String] = [:]) {
        self.kind = kind
        self.session = session
        self.to = to
        self.from = from
        self.body = body
    }
}
