public import Foundation

/// A host's pending request from a viewer (`session.request`).
public struct SessionRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var viewerId: String
    public var viewerName: String
    public var viewerKeyFingerprint: String?
    public var scope: SessionScope

    public init(id: String, viewerId: String, viewerName: String, viewerKeyFingerprint: String? = nil, scope: SessionScope) {
        self.id = id; self.viewerId = viewerId; self.viewerName = viewerName
        self.viewerKeyFingerprint = viewerKeyFingerprint; self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case id, viewerId, viewerName, viewerKeyFingerprint, scope }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        viewerId = try c.decode(String.self, forKey: .viewerId)
        viewerName = c.lenient(String.self, .viewerName) ?? ""
        viewerKeyFingerprint = c.lenient(String.self, .viewerKeyFingerprint)
        scope = c.lenient(SessionScope.self, .scope) ?? .view
    }
}

/// An approved session's admission (`session.ticket`): open `signalURL?ticket=`
/// with the device headers and signal to `peer` (TicketSignaling in CmuxVNCWebRTC).
public struct SessionTicket: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case viewer, host
    }

    public struct Peer: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// base64 X9.63: the key the peer's `fpSig` must verify with.
        public var signingKey: String

        public init(id: String, name: String, signingKey: String) {
            self.id = id; self.name = name; self.signingKey = signingKey
        }
    }

    public var sessionId: String
    /// The compact JWS the Session DO admits once.
    public var ticket: String
    public var signalURL: URL
    /// The cmux relay's credentials (paid plan), else empty; the app adds the user's relays.
    public var ice: [DeviceHubICEServer]
    public var peer: Peer
    public var role: Role
    public var scope: SessionScope

    public init(sessionId: String, ticket: String, signalURL: URL, ice: [DeviceHubICEServer], peer: Peer, role: Role, scope: SessionScope) {
        self.sessionId = sessionId; self.ticket = ticket; self.signalURL = signalURL; self.ice = ice
        self.peer = peer; self.role = role; self.scope = scope
    }

    /// `signalURL` with `?ticket=<jws>`, the URL the device opens.
    public var signalSocketURL: URL {
        var components = URLComponents(url: signalURL, resolvingAgainstBaseURL: true) ?? URLComponents()
        let query = (components.queryItems ?? []) + [URLQueryItem(name: "ticket", value: ticket)]
        components.queryItems = query
        return components.url ?? signalURL
    }
}

/// One server → device message on the User DO socket (PROTOCOL.md, WebSocket: User DO).
public enum DeviceHubPush: Sendable, Equatable {
    case devicesChanged
    case permissionsChanged(hostID: String?)
    case relaysChanged
    /// To the host: a viewer asks.
    case sessionRequest(SessionRequest)
    /// To both devices: the session is approved; signal with this.
    case sessionTicket(SessionTicket)
    /// To the viewer.
    case sessionDenied(sessionID: String)
    /// To both: end at once.
    case sessionRevoked(sessionID: String, reason: String?)
    case sessionEnded(sessionID: String, reason: String?)
    case pong
    /// A type this build does not know.
    case unknown(String)

    /// Decodes one text frame; nil when it is not a JSON message with a type.
    public init?(text: String) {
        guard let data = text.data(using: .utf8), let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let decoder = JSONDecoder()
        switch envelope.type {
        case "devices.changed": self = .devicesChanged
        case "permissions.changed": self = .permissionsChanged(hostID: envelope.hostId)
        case "relays.changed": self = .relaysChanged
        case "session.request":
            guard let request = try? decoder.decode(RequestMessage.self, from: data) else { return nil }
            self = .sessionRequest(request.session)
        case "session.ticket":
            guard let ticket = try? decoder.decode(SessionTicket.self, from: data) else { return nil }
            self = .sessionTicket(ticket)
        case "session.denied":
            guard let id = envelope.sessionId else { return nil }
            self = .sessionDenied(sessionID: id)
        case "session.revoked":
            guard let id = envelope.sessionId else { return nil }
            self = .sessionRevoked(sessionID: id, reason: envelope.reason)
        case "session.ended":
            guard let id = envelope.sessionId else { return nil }
            self = .sessionEnded(sessionID: id, reason: envelope.reason)
        case "pong": self = .pong
        default: self = .unknown(envelope.type)
        }
    }

    struct Envelope: Decodable {
        var type: String
        var hostId: String?
        var sessionId: String?
        var reason: String?
    }

    struct RequestMessage: Decodable {
        var session: SessionRequest
    }
}
