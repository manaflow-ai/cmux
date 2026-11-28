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
    /// Whose devices the session joins, as the hub authenticated them (PROTOCOL.md): `user` is one account,
    /// both devices signed in to it. Nil from a hub that does not say, which counts as not shown to be own.
    public var ownerKind: String?
    /// Who serves a host ticket on this Mac, as the acpmux daemon's share host relays it
    /// (``servedByDaemon`` or `"app"`); nil from the hub itself or an older relay (the app serves).
    /// A string, so a value this build does not know never drops the ticket.
    public var servedBy: String?
    /// A viewer ticket this device did not ask for: the hub pushed it (a share moved to this
    /// device, or a host that pushed its screen here). False from a hub that does not say.
    public var pushed: Bool
    /// The session this one replaced (a share that moved), else nil.
    public var movedFrom: String?

    /// `servedBy` of a ticket the acpmux daemon serves: the app neither serves nor ends it.
    public static let servedByDaemon = "daemon"

    public init(sessionId: String, ticket: String, signalURL: URL, ice: [DeviceHubICEServer], peer: Peer, role: Role, scope: SessionScope,
                ownerKind: String? = nil, servedBy: String? = nil, pushed: Bool = false, movedFrom: String? = nil) {
        self.sessionId = sessionId; self.ticket = ticket; self.signalURL = signalURL; self.ice = ice
        self.peer = peer; self.role = role; self.scope = scope; self.ownerKind = ownerKind; self.servedBy = servedBy
        self.pushed = pushed; self.movedFrom = movedFrom
    }

    enum CodingKeys: String, CodingKey { case sessionId, ticket, signalURL, ice, peer, role, scope, ownerKind, servedBy, pushed, movedFrom }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        ticket = try c.decode(String.self, forKey: .ticket)
        signalURL = try c.decode(URL.self, forKey: .signalURL)
        ice = try c.decode([DeviceHubICEServer].self, forKey: .ice)
        peer = try c.decode(Peer.self, forKey: .peer)
        role = try c.decode(Role.self, forKey: .role)
        scope = try c.decode(SessionScope.self, forKey: .scope)
        ownerKind = try c.decodeIfPresent(String.self, forKey: .ownerKind)
        servedBy = try c.decodeIfPresent(String.self, forKey: .servedBy)
        // Newer hub fields: absent (an older hub) or malformed reads as an ordinary ticket.
        pushed = c.flag(.pushed)
        movedFrom = c.lenient(String.self, .movedFrom)
    }

    /// The hub says both devices are signed in to one account: the person reaching their own machine.
    /// Read from the hub's own push, never from anything the viewer sends.
    public var isOwnAccount: Bool { ownerKind == "user" }

    /// The acpmux daemon serves this ticket (the daemon decides who serves, once per ticket).
    public var isServedByDaemon: Bool { servedBy == Self.servedByDaemon }

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
    /// The account's settings changed (`GET /v1/settings` again): "My agents can turn screen
    /// sharing and control on my machines".
    case settingsChanged
    /// To the host: a viewer asks.
    case sessionRequest(SessionRequest)
    /// To both devices: the session is approved; signal with this.
    case sessionTicket(SessionTicket)
    /// To the viewer.
    case sessionDenied(sessionID: String)
    /// To both: end at once.
    case sessionRevoked(sessionID: String, reason: String?)
    /// `movedTo`: with reason `moved`, the session that replaced this one (the share moved), else nil.
    case sessionEnded(sessionID: String, reason: String?, movedTo: String? = nil)
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
        case "settings.changed": self = .settingsChanged
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
            // `approve_failed:<step>` keeps the hub's step with its reason (MacScreenEndReason reads the prefix).
            let reason = envelope.step.flatMap { step in envelope.reason.map { "\($0):\(step)" } } ?? envelope.reason
            self = .sessionRevoked(sessionID: id, reason: reason)
        case "session.ended":
            guard let id = envelope.sessionId else { return nil }
            self = .sessionEnded(sessionID: id, reason: envelope.reason, movedTo: envelope.movedTo)
        case "pong": self = .pong
        default: self = .unknown(envelope.type)
        }
    }

    struct Envelope: Decodable {
        var type: String
        var hostId: String?
        var sessionId: String?
        var reason: String?
        var movedTo: String?
        /// With `approve_failed`: the part of the hub's setup that threw (`init`, `entitlement`, `relay`, `tickets`).
        var step: String?
    }

    struct RequestMessage: Decodable {
        var session: SessionRequest
    }
}
