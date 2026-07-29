import Foundation

/// The address shape used to reach an attach route.
public enum CmxAttachEndpoint: Equatable, Sendable {
    /// The maximum number of reachability hints accepted for one Iroh peer.
    public static let maximumIrohPathHintCount = 16

    /// A direct host and TCP port.
    case hostPort(host: String, port: Int)
    /// An authenticated Iroh identity plus untrusted reachability hints.
    case peer(identity: CmxIrohPeerIdentity, pathHints: [CmxIrohPathHint])
    /// A URL-based transport endpoint.
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
        case pathHints = "path_hints"
        case url
    }

    private enum EndpointType: String, Codable {
        case hostPort = "host_port"
        case peer
        case url
    }

    /// Decodes and validates an attach endpoint.
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
            let identity = try CmxIrohPeerIdentity(
                endpointID: try container.decode(String.self, forKey: .id)
            )
            if let pathHints = try container.decodeIfPresent(
                [CmxIrohPathHint].self,
                forKey: .pathHints
            ) {
                self = .peer(identity: identity, pathHints: pathHints)
            } else {
                self = try .peer(
                    id: identity.endpointID,
                    relayHint: try container.decodeIfPresent(String.self, forKey: .relayHint),
                    directAddrs: try container.decodeIfPresent(
                        [String].self,
                        forKey: .directAddrs
                    ) ?? [],
                    relayURL: try container.decodeIfPresent(String.self, forKey: .relayURL)
                )
            }
        case .url:
            self = try .url(container.decode(String.self, forKey: .url))
        }
    }

    /// Encodes the endpoint while omitting unsafe legacy Iroh hint forms.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hostPort(host, port):
            try container.encode(EndpointType.hostPort, forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case let .peer(identity, pathHints):
            try container.encode(EndpointType.peer, forKey: .type)
            try container.encode(identity.endpointID, forKey: .id)
            // Encoding is deterministic: wall-clock freshness is applied by
            // the caller's disclosure/persistence boundary. Structurally
            // unsafe inert legacy values are never re-emitted.
            let wireSafePathHints = pathHints.filter(\.isSafeForCurrentWireFormat)
            if !wireSafePathHints.isEmpty {
                try container.encode(wireSafePathHints, forKey: .pathHints)
            }

            // Legacy fields cannot represent observation or expiry metadata.
            // Downgrade only timeless safe hints, otherwise an expired/future
            // path would be promoted indefinitely for an older consumer.
            let legacySafePathHints = wireSafePathHints.filter {
                $0.observedAt == nil && $0.expiresAt == nil
            }
            let relayHint = legacySafePathHints.first {
                $0.kind == .relayIdentifier
            }?.value
            // Legacy `direct_addrs` cannot carry expiry, privacy, or network
            // profile. Emitting private fallbacks there would silently promote
            // them for old clients, so only public primary addresses downgrade.
            let directAddrs = legacySafePathHints
                .filter { $0.kind == .directAddress && $0.use == .primary }
                .map(\.value)
            let relayURL = legacySafePathHints.first {
                $0.kind == .relayURL
            }?.value
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

/// Validation failures for attach-route endpoints.
public enum CmxAttachRouteError: Error, Equatable, Sendable {
    /// A host/port route has an empty host.
    case emptyHost
    /// An Iroh peer route has an empty peer identity.
    case emptyPeerID
    /// An Iroh direct-address hint is empty.
    case emptyPeerAddress
    /// A URL or relay hint is empty.
    case emptyURL
    /// A host/port route uses a port outside the valid TCP range.
    case invalidPort(Int)
    /// A peer route exceeded ``CmxAttachEndpoint/maximumIrohPathHintCount``.
    case tooManyPeerPathHints(actual: Int, maximum: Int)
    /// The endpoint shape does not match its declared transport kind.
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

    /// Validates that the endpoint shape and route kind agree.
    public func validate() throws {
        switch endpoint {
        case let .hostPort(host, port):
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyHost
            }
            guard (1...65535).contains(port) else {
                throw CmxAttachRouteError.invalidPort(port)
            }
        case let .peer(identity, pathHints):
            guard !identity.endpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachRouteError.emptyPeerID
            }
            guard pathHints.count <= CmxAttachEndpoint.maximumIrohPathHintCount else {
                throw CmxAttachRouteError.tooManyPeerPathHints(
                    actual: pathHints.count,
                    maximum: CmxAttachEndpoint.maximumIrohPathHintCount
                )
            }
            for pathHint in pathHints {
                do {
                    try pathHint.validate()
                } catch CmxIrohPathHintError.emptyValue {
                    switch pathHint.kind {
                    case .directAddress:
                        throw CmxAttachRouteError.emptyPeerAddress
                    case .relayIdentifier, .relayURL:
                        throw CmxAttachRouteError.emptyURL
                    }
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
        case macUserEmail
        case macUserID
        case macPairingCompatibilityVersion
        case macAppVersion
        case macAppBuild
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
    /// The signed-in Mac account email the phone must match before pairing.
    public let macUserEmail: String?
    /// The opaque Stack user id for the Mac account. Public pairing QR codes
    /// carry this instead of an email so the phone can reject the wrong
    /// signed-in account without exposing an enumerable email address.
    public let macUserID: String?
    /// Shared mobile pairing compatibility level reported by the Mac.
    public let macPairingCompatibilityVersion: Int?
    /// The Mac app's marketing version, displayed with compatibility warnings.
    public let macAppVersion: String?
    /// The Mac app's build number, displayed with version mismatch warnings when present.
    public let macAppBuild: String?
    public let routes: [CmxAttachRoute]
    /// When the ticket's attach token stops being usable, or `nil` for tickets
    /// that never expire (the pairing QR carries no token and no expiry; Stack
    /// auth is the host's sole authorization gate). Expiry is data for the
    /// token consumers (`MobileCoreRPCClient`, the host's ticket store), not a
    /// structural validity condition; see ``isExpired(at:)``.
    public let expiresAt: Date?
    public let authToken: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            workspaceID: container.decode(String.self, forKey: .workspaceID),
            terminalID: container.decodeIfPresent(String.self, forKey: .terminalID),
            macDeviceID: container.decode(String.self, forKey: .macDeviceID),
            macDisplayName: container.decodeIfPresent(String.self, forKey: .macDisplayName),
            macUserEmail: container.decodeIfPresent(String.self, forKey: .macUserEmail),
            macUserID: container.decodeIfPresent(String.self, forKey: .macUserID),
            macPairingCompatibilityVersion: container.decodeIfPresent(
                Int.self,
                forKey: .macPairingCompatibilityVersion
            ),
            macAppVersion: container.decodeIfPresent(String.self, forKey: .macAppVersion),
            macAppBuild: container.decodeIfPresent(String.self, forKey: .macAppBuild),
            routes: container.decode([CmxAttachRoute].self, forKey: .routes),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            authToken: try Self.decodeAuthToken(from: decoder)
        )
        try validate()
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
        macUserEmail: String? = nil,
        macUserID: String? = nil,
        macPairingCompatibilityVersion: Int? = nil,
        macAppVersion: String? = nil,
        macAppBuild: String? = nil,
        routes: [CmxAttachRoute],
        expiresAt: Date? = nil,
        authToken: String? = nil
    ) throws {
        self.version = version
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        self.macDisplayName = macDisplayName
        self.macUserEmail = macUserEmail
        self.macUserID = macUserID
        self.macPairingCompatibilityVersion = macPairingCompatibilityVersion
        self.macAppVersion = macAppVersion
        self.macAppBuild = macAppBuild
        self.routes = routes
        self.expiresAt = expiresAt
        self.authToken = authToken
        try validate()
    }

    /// Structural validity only. Expiry is intentionally NOT validated here:
    /// a scanned pairing QR must keep working however long it sat on screen
    /// (the host authorizes by Stack account, not by ticket age). Token-based
    /// consumers check ``isExpired(at:)`` where the token is actually used.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CmxAttachTicketError.unsupportedVersion(version)
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

    /// Whether the ticket's attach token lifetime has elapsed at `now`.
    /// Tickets without an expiry (`expiresAt == nil`, e.g. decoded from the
    /// pairing QR) never expire.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= now
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

/// Optional privacy-safe identity for the exact native connection underneath a
/// byte transport.
///
/// Release gates use this to prove that credential refresh did not replace a
/// live transport. The value is process-local and must never be persisted or
/// sent to a server.
public protocol CmxByteTransportContinuityIdentifying: CmxByteTransport {
    /// Returns a process-local identifier for the currently connected native
    /// transport, or `nil` before connection or after teardown.
    func transportContinuityID() async -> UInt64?
}

/// A privacy-safe handle that waits for one exact native transport to close.
///
/// The handle captures the transport generation at creation time, so callers
/// can retain it across owner teardown without accidentally observing a later
/// replacement connection.
public struct CmxTransportClosureObservation: Sendable {
    private let waitUntilClosedOperation: @Sendable () async -> Void

    public init(waitUntilClosed: @escaping @Sendable () async -> Void) {
        self.waitUntilClosedOperation = waitUntilClosed
    }

    public func waitUntilClosed() async {
        await waitUntilClosedOperation()
    }
}

/// Optional close notification for the exact native transport currently
/// installed underneath a byte transport.
public protocol CmxByteTransportClosureObserving: CmxByteTransport {
    func transportClosureObservation() async -> CmxTransportClosureObservation?
}

/// Independently framed server-event bytes delivered outside the RPC control stream.
public typealias CmxIndependentEventByteStream = AsyncThrowingStream<Data, any Error>

/// Opens the one bounded event byte stream associated with an exact transport intent.
public typealias CmxIndependentEventByteStreamProvider = @Sendable (
    CmxByteTransportRequest
) async throws -> CmxIndependentEventByteStream

public protocol CmxByteTransportFactory: Sendable {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport
    func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport
}

extension CmxByteTransportFactory {
    /// Compatibility path for transports whose peer intent is fully represented by the route.
    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        try makeTransport(for: request.route)
    }
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

    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        guard let factory = factories[request.route.kind] else {
            throw CmxRouteTransportFactoryError.unsupportedRouteKind(request.route.kind)
        }
        return try factory.makeTransport(for: request)
    }
}
