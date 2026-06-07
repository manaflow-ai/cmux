import Foundation

public enum CmxAttachEndpoint: Equatable, Sendable {
    case hostPort(host: String, port: Int)
    case peer(id: String, relayHint: String?, directAddrs: [String], relayURL: String?)
    case url(String)
}

extension CmxAttachEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case host
        case port
        case id
        case relayHint = "relay_hint"
        case directAddrs = "direct_addrs"
        case relayURL = "relay_url"
        case url
    }

    private enum EndpointType: String, Codable {
        case hostPort = "host_port"
        case peer
        case url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EndpointType.self, forKey: .type)
        switch type {
        case .hostPort:
            self = try .hostPort(
                host: container.decode(String.self, forKey: .host),
                port: container.decode(Int.self, forKey: .port)
            )
        case .peer:
            self = try .peer(
                id: container.decode(String.self, forKey: .id),
                relayHint: container.decodeIfPresent(String.self, forKey: .relayHint),
                directAddrs: container.decodeIfPresent([String].self, forKey: .directAddrs) ?? [],
                relayURL: container.decodeIfPresent(String.self, forKey: .relayURL)
            )
        case .url:
            self = try .url(container.decode(String.self, forKey: .url))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hostPort(host, port):
            try container.encode(EndpointType.hostPort, forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case let .peer(id, relayHint, directAddrs, relayURL):
            try container.encode(EndpointType.peer, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(relayHint, forKey: .relayHint)
            if !directAddrs.isEmpty {
                try container.encode(directAddrs, forKey: .directAddrs)
            }
            try container.encodeIfPresent(relayURL, forKey: .relayURL)
        case let .url(url):
            try container.encode(EndpointType.url, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }
}

public enum CmxAttachRouteError: Error, Equatable, Sendable {
    case emptyHost
    case emptyPeerID
    case emptyPeerAddress
    case emptyURL
    case invalidPort(Int)
    case endpointMismatch(kind: CmxAttachTransportKind, endpoint: CmxAttachEndpoint)
}

public struct CmxAttachRoute: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case endpoint
        case priority
    }

    public let id: String
    public let kind: CmxAttachTransportKind
    public let endpoint: CmxAttachEndpoint
    public let priority: Int

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(CmxAttachTransportKind.self, forKey: .kind),
            endpoint: container.decode(CmxAttachEndpoint.self, forKey: .endpoint),
            priority: container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        )
    }

    public init(
        id: String,
        kind: CmxAttachTransportKind,
        endpoint: CmxAttachEndpoint,
        priority: Int = 0
    ) throws {
        self.id = id
        self.kind = kind
        self.endpoint = endpoint
        self.priority = priority
        try validate()
    }

    public func validate() throws {
        switch endpoint {
        case let .hostPort(host, port):
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyHost
            }
            guard (1...65535).contains(port) else {
                throw CmxAttachRouteError.invalidPort(port)
            }
        case let .peer(id, _, directAddrs, relayURL):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyPeerID
            }
            for address in directAddrs {
                guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CmxAttachRouteError.emptyPeerAddress
                }
            }
            if let relayURL {
                guard !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CmxAttachRouteError.emptyURL
                }
            }
        case let .url(url):
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyURL
            }
        }

        switch (kind, endpoint) {
        case (.tailscale, .hostPort), (.debugLoopback, .hostPort), (.iroh, .peer), (.websocket, .url):
            break
        default:
            throw CmxAttachRouteError.endpointMismatch(kind: kind, endpoint: endpoint)
        }
    }
}

public enum CmxAttachTicketError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case expired
    case noRoutes
    case emptyAuthToken
}

public struct CmxAttachTicket: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The canonical on-the-wire keys. Most fields use camelCase; the auth
    /// token field is the one historical exception (`auth_token`).
    ///
    /// Encoding stays byte-compatible with what the mac side of PR 5079 already
    /// produces and decodes (this exact type is shared by both the iOS and mac
    /// app via `CMUXMobileCore`), so the mixed convention is preserved on the
    /// encode path. Decoding is tolerant: it accepts both the canonical
    /// `auth_token` key and a normalized camelCase `authToken` so a future
    /// producer can migrate the token field without breaking older clients.
    /// See ``decodeAuthToken(from:)``.
    private enum CodingKeys: String, CodingKey {
        case version
        case workspaceID
        case terminalID
        case macDeviceID
        case macDisplayName
        case routes
        case expiresAt
        case authToken = "auth_token"
    }

    /// Tolerant decode keys for the auth-token field only.
    ///
    /// Holds both the canonical `auth_token` key and the normalized `authToken`
    /// camelCase key so a payload speaking either convention decodes. The
    /// canonical key wins when both are present.
    private enum AuthTokenCodingKeys: String, CodingKey {
        case canonical = "auth_token"
        case camelCase = "authToken"
    }

    public let version: Int
    public let workspaceID: String
    public let terminalID: String?
    public let macDeviceID: String
    public let macDisplayName: String?
    public let routes: [CmxAttachRoute]
    public let expiresAt: Date
    public let authToken: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            workspaceID: container.decode(String.self, forKey: .workspaceID),
            terminalID: container.decodeIfPresent(String.self, forKey: .terminalID),
            macDeviceID: container.decode(String.self, forKey: .macDeviceID),
            macDisplayName: container.decodeIfPresent(String.self, forKey: .macDisplayName),
            routes: container.decode([CmxAttachRoute].self, forKey: .routes),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            authToken: try Self.decodeAuthToken(from: decoder)
        )
        try validate(now: Date())
    }

    /// Decode the auth token tolerantly, accepting either the canonical
    /// `auth_token` key or the normalized `authToken` key.
    ///
    /// - Parameter decoder: The decoder for the ticket payload.
    /// - Returns: The auth token if present under either key (`auth_token`
    ///   takes precedence), otherwise `nil`.
    private static func decodeAuthToken(from decoder: Decoder) throws -> String? {
        let container = try decoder.container(keyedBy: AuthTokenCodingKeys.self)
        if let canonical = try container.decodeIfPresent(String.self, forKey: .canonical) {
            return canonical
        }
        return try container.decodeIfPresent(String.self, forKey: .camelCase)
    }

    public init(
        version: Int = Self.currentVersion,
        workspaceID: String,
        terminalID: String?,
        macDeviceID: String,
        macDisplayName: String?,
        routes: [CmxAttachRoute],
        expiresAt: Date,
        authToken: String? = nil
    ) throws {
        self.version = version
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.routes = routes
        self.expiresAt = expiresAt
        self.authToken = authToken
        try validate(now: Date())
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw CmxAttachTicketError.unsupportedVersion(version)
        }
        guard expiresAt > now else {
            throw CmxAttachTicketError.expired
        }
        if let authToken {
            guard !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachTicketError.emptyAuthToken
            }
        }
        guard !routes.isEmpty else {
            throw CmxAttachTicketError.noRoutes
        }
        for route in routes {
            try route.validate()
        }
    }

    public func preferredRoute(supportedKinds: [CmxAttachTransportKind]) -> CmxAttachRoute? {
        guard !supportedKinds.isEmpty else {
            return nil
        }
        let orderedRoutes = routes.sorted { left, right in
            if left.priority == right.priority {
                return left.id < right.id
            }
            return left.priority < right.priority
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.first { supportedKinds.contains($0.kind) }
    }
}

public protocol CmxByteTransport: Sendable {
    func connect() async throws
    func receive() async throws -> Data?
    func send(_ data: Data) async throws
    func close() async
}

public protocol CmxByteTransportFactory: Sendable {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport
}

public protocol CmxRouteAwareByteTransportFactory: CmxByteTransportFactory {
    var supportedKinds: [CmxAttachTransportKind] { get }
}

public struct CmxRouteTransportFactoryRegistration: Sendable {
    public var kind: CmxAttachTransportKind
    public var factory: any CmxByteTransportFactory

    public init(kind: CmxAttachTransportKind, factory: any CmxByteTransportFactory) {
        self.kind = kind
        self.factory = factory
    }
}

public enum CmxRouteTransportFactoryError: Error, Equatable, Sendable {
    case duplicateRouteKind(CmxAttachTransportKind)
    case unsupportedRouteKind(CmxAttachTransportKind)
}

public struct CmxRouteTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind]
    private let factories: [CmxAttachTransportKind: any CmxByteTransportFactory]

    public init(_ registrations: [CmxRouteTransportFactoryRegistration]) throws {
        var factories: [CmxAttachTransportKind: any CmxByteTransportFactory] = [:]
        var supportedKinds: [CmxAttachTransportKind] = []

        for registration in registrations {
            guard factories[registration.kind] == nil else {
                throw CmxRouteTransportFactoryError.duplicateRouteKind(registration.kind)
            }
            factories[registration.kind] = registration.factory
            supportedKinds.append(registration.kind)
        }

        self.factories = factories
        self.supportedKinds = supportedKinds
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard let factory = factories[route.kind] else {
            throw CmxRouteTransportFactoryError.unsupportedRouteKind(route.kind)
        }
        return try factory.makeTransport(for: route)
    }
}
