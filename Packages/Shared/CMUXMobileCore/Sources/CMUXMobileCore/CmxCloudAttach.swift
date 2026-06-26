import Foundation

/// Errors raised while turning a Cloud VM attach endpoint into a
/// ``CmxAttachTicket``.
public enum CmxCloudAttachError: Error, Equatable, Sendable {
    /// The endpoint declared a transport this client cannot dial. iOS cloud
    /// attach only speaks the cmuxd-remote WebSocket; the SSH endpoint (a
    /// provider fallback) is not usable from the phone. The associated value is
    /// the transport string the backend reported.
    case unsupportedTransport(String)
    /// The endpoint carried no RPC daemon lease. The phone drives terminals
    /// over the cmuxd-remote JSON-RPC daemon — the same `mobile.*` protocol it
    /// speaks to a paired Mac — so a PTY-only endpoint cannot back a mobile
    /// session. Callers must request the daemon (`requireDaemon: true`).
    case missingDaemon
    /// The daemon URL was empty or not a `ws://` / `wss://` endpoint. The
    /// associated value is the offending URL string.
    case invalidDaemonURL(String)
    /// The daemon lease carried no token. The short-lived lease token is the
    /// host's authorization gate for a cloud session, mirroring the Mac attach
    /// token, so a tokenless lease authorizes nothing.
    case missingDaemonToken
}

/// A Cloud VM attach endpoint as returned by the backend
/// `POST /api/vm/{id}/attach-endpoint` route — specifically the
/// `transport: "websocket"` shape (`WebSocketPtyEndpoint` in
/// `web/services/vms/drivers/types.ts`).
///
/// This is the cloud counterpart to a pairing QR (``CmxPairingQRCode``):
/// instead of Tailscale `host:port` routes to a Mac, the backend hands the
/// phone short-lived `wss://` leases to a running Cloud VM — a terminal PTY
/// stream (`terminal`) and, when requested, a cmuxd-remote JSON-RPC daemon
/// (`daemon`). ``CmxCloudAttach`` turns it into a ``CmxAttachTicket`` so the
/// existing attach-ticket + route model can drive a cloud session with no Mac
/// and no Tailscale (issue #6700).
///
/// The wire shape is flat for the terminal lease (its fields sit at the top
/// level alongside `transport`) and nested for the optional `daemon`. Both
/// leases share the same field set, so they are modelled by ``Lease``.
public struct CmxCloudAttachEndpoint: Codable, Equatable, Sendable {
    /// A single short-lived WebSocket lease minted by the backend: a `wss://`
    /// URL, the handshake headers the client should send, the lease token, an
    /// opaque session id, and the lease's Unix expiry (seconds).
    public struct Lease: Codable, Equatable, Sendable {
        public let url: String
        /// Handshake headers the client should send when opening the socket
        /// (for example an `Authorization` bearer). Empty when the backend
        /// authorizes purely by token; preserved so a future WebSocket
        /// transport can replay them verbatim.
        public let headers: [String: String]
        public let token: String
        public let sessionID: String
        /// Lease expiry as a Unix timestamp in **seconds** (the backend stores
        /// `new Date(expiresAtUnix * 1000)`), matching
        /// `Date(timeIntervalSince1970:)`.
        public let expiresAtUnix: Double

        private enum CodingKeys: String, CodingKey {
            case url
            case headers
            case token
            case sessionID = "sessionId"
            case expiresAtUnix
        }

        public init(
            url: String,
            headers: [String: String] = [:],
            token: String,
            sessionID: String,
            expiresAtUnix: Double
        ) {
            self.url = url
            self.headers = headers
            self.token = token
            self.sessionID = sessionID
            self.expiresAtUnix = expiresAtUnix
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            token = try container.decode(String.self, forKey: .token)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            expiresAtUnix = try container.decode(Double.self, forKey: .expiresAtUnix)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(url, forKey: .url)
            if !headers.isEmpty {
                try container.encode(headers, forKey: .headers)
            }
            try container.encode(token, forKey: .token)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(expiresAtUnix, forKey: .expiresAtUnix)
        }
    }

    /// The transport label. Always `"websocket"` for an endpoint this type can
    /// represent; SSH endpoints have a different shape and are rejected up
    /// front by ``CmxCloudAttach/decode(_:)``.
    public let transport: String
    /// The terminal PTY lease (its fields arrive flat at the top level).
    public let terminal: Lease
    /// The cmuxd-remote JSON-RPC daemon lease, present when the attach was
    /// opened with `requireDaemon`. The mobile session drives terminals over
    /// this lease.
    public let daemon: Lease?

    private enum CodingKeys: String, CodingKey {
        case transport
        case url
        case headers
        case token
        case sessionID = "sessionId"
        case expiresAtUnix
        case daemon
    }

    public init(transport: String = CmxCloudAttach.webSocketTransport, terminal: Lease, daemon: Lease? = nil) {
        self.transport = transport
        self.terminal = terminal
        self.daemon = daemon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? CmxCloudAttach.webSocketTransport
        // The terminal lease is flat at the top level: decode it from the same
        // container by keys, not from a nested object.
        terminal = try Lease(from: decoder)
        daemon = try container.decodeIfPresent(Lease.self, forKey: .daemon)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transport, forKey: .transport)
        // Flatten the terminal lease back into the top-level object.
        try container.encode(terminal.url, forKey: .url)
        if !terminal.headers.isEmpty {
            try container.encode(terminal.headers, forKey: .headers)
        }
        try container.encode(terminal.token, forKey: .token)
        try container.encode(terminal.sessionID, forKey: .sessionID)
        try container.encode(terminal.expiresAtUnix, forKey: .expiresAtUnix)
        try container.encodeIfPresent(daemon, forKey: .daemon)
    }
}

/// Builds a ``CmxAttachTicket`` for a Cloud VM from the backend attach-endpoint
/// response, the cloud-route counterpart to ``CmxPairingQRCode``.
///
/// A paired Mac hands the phone Tailscale `host:port` routes; a Cloud VM hands
/// it a `wss://` cmuxd-remote daemon lease. Both flow through the same
/// ``CmxAttachTicket`` + ``CmxAttachRoute`` model, so the existing connection
/// machinery drives either backend. As with a scanned pairing QR, the ticket
/// comes back unscoped with an empty `macDeviceID`: the host's identity arrives
/// post-handshake from `mobile.host.status`. Unlike the QR, the ticket carries
/// the lease token and its expiry, since a cloud lease is short-lived.
public struct CmxCloudAttach: Sendable {
    /// The transport label the backend uses for a cmuxd-remote WebSocket
    /// endpoint (`web/services/vms/drivers/types.ts`).
    public static let webSocketTransport = "websocket"

    /// The route id the cloud attach ticket carries for the cmuxd-remote
    /// daemon. Stable and distinct from the Mac path's `tailscale` route ids.
    public static let daemonRouteID = "cloud_rpc"

    /// The priority assigned to the daemon route. There is a single cloud route
    /// today; the value mirrors the first synthesized Tailscale priority so
    /// mixed ticket inspection stays predictable.
    public static let daemonRoutePriority = 10

    /// Creates the codec. It is stateless: construct one inline at the call
    /// site.
    public init() {}

    /// Decode a `POST /api/vm/{id}/attach-endpoint` response body into a
    /// ``CmxCloudAttachEndpoint``.
    ///
    /// - Parameter data: The raw JSON response body.
    /// - Throws: ``CmxCloudAttachError/unsupportedTransport(_:)`` when the
    ///   backend returned a non-WebSocket endpoint (for example the SSH
    ///   fallback, which the phone cannot dial), or a `DecodingError` when the
    ///   payload is malformed.
    public func decode(_ data: Data) throws -> CmxCloudAttachEndpoint {
        // Probe the transport first so the SSH fallback (a differently-shaped
        // endpoint the phone can't dial) surfaces as a typed
        // `unsupportedTransport` error rather than an opaque `DecodingError`
        // from the WebSocket-shaped decode. One decoder is reused across both
        // passes.
        let decoder = JSONDecoder()
        let probe = try decoder.decode(CmxCloudAttachTransportProbe.self, from: data)
        guard probe.transport == Self.webSocketTransport else {
            throw CmxCloudAttachError.unsupportedTransport(probe.transport)
        }
        return try decoder.decode(CmxCloudAttachEndpoint.self, from: data)
    }

    /// Build a ``CmxAttachTicket`` that drives a session against a Cloud VM,
    /// reusing the same attach-ticket + route model a paired Mac uses.
    ///
    /// The ticket carries a single `.websocket` route to the cmuxd-remote
    /// JSON-RPC daemon — the cloud counterpart to a Mac's Tailscale route — and
    /// the daemon lease's token as the attach token, expiring when the lease
    /// does. The VM is identified by the route URL itself
    /// (`wss://{vmId}.vm.<provider>/rpc`), so no separate id need ride in the
    /// ticket. As with a scanned pairing QR, `macDeviceID` stays empty and the
    /// shell adopts the host-reported identity once connected.
    ///
    /// - Parameters:
    ///   - endpoint: The decoded attach-endpoint response.
    ///   - displayName: An optional human-readable label for the VM, shown in
    ///     the UI before the host reports its own identity.
    ///   - macUserID: The signed-in account's Stack user id, recorded so the
    ///     same account gate the Mac path applies also covers cloud sessions.
    /// - Returns: A validated unscoped attach ticket with one WebSocket route.
    /// - Throws: ``CmxCloudAttachError`` when the endpoint cannot back a mobile
    ///   session, or ``CmxAttachRouteError`` / ``CmxAttachTicketError`` when the
    ///   derived route or ticket is structurally invalid.
    public func ticket(
        from endpoint: CmxCloudAttachEndpoint,
        displayName: String? = nil,
        macUserID: String? = nil
    ) throws -> CmxAttachTicket {
        guard endpoint.transport == Self.webSocketTransport else {
            throw CmxCloudAttachError.unsupportedTransport(endpoint.transport)
        }
        guard let daemon = endpoint.daemon else {
            throw CmxCloudAttachError.missingDaemon
        }
        let daemonURL = daemon.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isWebSocketURL(daemonURL) else {
            throw CmxCloudAttachError.invalidDaemonURL(daemon.url)
        }
        let token = daemon.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CmxCloudAttachError.missingDaemonToken
        }

        let route = try CmxAttachRoute(
            id: Self.daemonRouteID,
            kind: .websocket,
            endpoint: .url(daemonURL),
            priority: Self.daemonRoutePriority
        )
        return try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: displayName,
            macUserEmail: nil,
            macUserID: macUserID,
            routes: [route],
            expiresAt: Self.expiry(fromUnix: daemon.expiresAtUnix),
            authToken: token
        )
    }

    /// Convenience: decode a response body and build the attach ticket in one
    /// step. Equivalent to ``decode(_:)`` followed by
    /// ``ticket(from:displayName:macUserID:)``.
    public func ticket(
        fromResponse data: Data,
        displayName: String? = nil,
        macUserID: String? = nil
    ) throws -> CmxAttachTicket {
        let endpoint = try decode(data)
        return try ticket(from: endpoint, displayName: displayName, macUserID: macUserID)
    }
}

private extension CmxCloudAttach {
    /// Whether `raw` is a usable WebSocket URL (`ws://` or `wss://`).
    static func isWebSocketURL(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "ws" || scheme == "wss"
    }

    /// Convert a Unix expiry (seconds) into a `Date`, or `nil` for a missing or
    /// non-positive value so the ticket is treated as non-expiring rather than
    /// instantly stale at the 1970 epoch.
    static func expiry(fromUnix seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Minimal `transport`-only view used to reject non-WebSocket endpoints before
/// attempting the full (WebSocket-shaped) decode, so an SSH fallback surfaces
/// as ``CmxCloudAttachError/unsupportedTransport(_:)`` rather than an opaque
/// `DecodingError`.
private struct CmxCloudAttachTransportProbe: Decodable {
    let transport: String

    private enum CodingKeys: String, CodingKey {
        case transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? CmxCloudAttach.webSocketTransport
    }
}
