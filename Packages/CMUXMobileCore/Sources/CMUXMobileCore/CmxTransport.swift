import Foundation

public enum CmxAttachEndpoint: Equatable, Sendable {
    case hostPort(host: String, port: Int)
    case peer(id: String, relayHint: String?)
    case url(String)
}

extension CmxAttachEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case host
        case port
        case id
        case relayHint = "relay_hint"
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
                relayHint: container.decodeIfPresent(String.self, forKey: .relayHint)
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
        case let .peer(id, relayHint):
            try container.encode(EndpointType.peer, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(relayHint, forKey: .relayHint)
        case let .url(url):
            try container.encode(EndpointType.url, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }
}

public enum CmxAttachRouteError: Error, Equatable, Sendable {
    case emptyHost
    case emptyPeerID
    case emptyURL
    case invalidPort(Int)
    case endpointMismatch(kind: CmxAttachTransportKind, endpoint: CmxAttachEndpoint)
}

public struct CmxAttachRoute: Codable, Equatable, Sendable {
    public var id: String
    public var kind: CmxAttachTransportKind
    public var endpoint: CmxAttachEndpoint
    public var priority: Int

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
        case let .peer(id, _):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyPeerID
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
}

public struct CmxAttachTicket: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var workspaceID: String
    public var terminalID: String?
    public var macDeviceID: String
    public var macDisplayName: String?
    public var routes: [CmxAttachRoute]
    public var expiresAt: Date

    public init(
        version: Int = Self.currentVersion,
        workspaceID: String,
        terminalID: String?,
        macDeviceID: String,
        macDisplayName: String?,
        routes: [CmxAttachRoute],
        expiresAt: Date
    ) throws {
        self.version = version
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.routes = routes
        self.expiresAt = expiresAt
        try validate(now: .distantPast)
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw CmxAttachTicketError.unsupportedVersion(version)
        }
        guard expiresAt > now else {
            throw CmxAttachTicketError.expired
        }
        guard !routes.isEmpty else {
            throw CmxAttachTicketError.noRoutes
        }
        for route in routes {
            try route.validate()
        }
    }

    public func preferredRoute(supportedKinds: [CmxAttachTransportKind]) -> CmxAttachRoute? {
        let orderedRoutes = routes.sorted { left, right in
            if left.priority == right.priority {
                return left.id < right.id
            }
            return left.priority < right.priority
        }
        guard !supportedKinds.isEmpty else {
            return orderedRoutes.first
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
