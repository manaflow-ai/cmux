/// A candidate exchanged during WebRTC's trickle-ICE signaling handshake.
public struct CmxWebRTCCandidate: Codable, Equatable, Sendable {
    /// Candidate SDP text.
    public let sdp: String
    /// Media-section index associated with the candidate.
    public let sdpMLineIndex: Int32
    /// Media-section id associated with the candidate.
    public let sdpMid: String?

    /// Creates a candidate value.
    public init(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }
}

/// One newline-delimited signaling message exchanged over the bootstrap TCP connection.
public enum CmxWebRTCSignalMessage: Codable, Equatable, Sendable {
    /// Authenticates the signaling connection with the per-listener route token.
    case hello(token: String)
    /// Sends an SDP offer.
    case offer(sdp: String)
    /// Sends an SDP answer.
    case answer(sdp: String)
    /// Sends one trickle-ICE candidate.
    case candidate(CmxWebRTCCandidate)
    /// Closes the signaling session.
    case close
    /// Reports a non-secret protocol error.
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case sdp
        case candidate
        case message
    }

    private enum Kind: String, Codable {
        case hello
        case offer
        case answer
        case candidate
        case close
        case error
    }

    /// Decodes a signaling message.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hello:
            self = .hello(token: try container.decode(String.self, forKey: .token))
        case .offer:
            self = .offer(sdp: try container.decode(String.self, forKey: .sdp))
        case .answer:
            self = .answer(sdp: try container.decode(String.self, forKey: .sdp))
        case .candidate:
            self = .candidate(try container.decode(CmxWebRTCCandidate.self, forKey: .candidate))
        case .close:
            self = .close
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    /// Encodes a signaling message.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(token):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(token, forKey: .token)
        case let .offer(sdp):
            try container.encode(Kind.offer, forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case let .answer(sdp):
            try container.encode(Kind.answer, forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case let .candidate(candidate):
            try container.encode(Kind.candidate, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
        case .close:
            try container.encode(Kind.close, forKey: .kind)
        case let .error(message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}
