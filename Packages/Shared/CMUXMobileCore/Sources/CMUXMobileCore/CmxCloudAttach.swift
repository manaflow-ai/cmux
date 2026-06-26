import Foundation

/// Errors raised while decoding a Cloud VM attach endpoint.
public enum CmxCloudAttachError: Error, Equatable, Sendable {
    /// The endpoint declared a transport this client cannot dial. iOS cloud
    /// attach only speaks the cmuxd-remote WebSocket; the SSH endpoint (a
    /// provider fallback) is not usable from the phone. The associated value is
    /// the transport string the backend reported.
    case unsupportedTransport(String)
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
/// (`daemon`). It lets a signed-in device drive a working terminal with no Mac
/// and no Tailscale (issue #6700).
///
/// This is a **dedicated cloud payload**, not a ``CmxAttachTicket``. The cmuxd-
/// remote WebSocket handshake authenticates with `{ token, session_id }` (see
/// `web/scripts/test-cloud-vm-ws-auth.ts`) and some providers also require
/// per-lease handshake `headers` (E2B's `e2b-traffic-access-token`). The
/// Mac-oriented ``CmxAttachTicket`` / ``CmxAttachRoute`` model carries only a
/// URL + token, with no slot for `session_id` or `headers`, so collapsing a
/// lease into a route would silently drop fields the handshake needs. The macOS
/// app models the same endpoint with its own `WorkspaceRemoteWebSocketDaemonEndpoint`
/// (url + token + sessionId) for the same reason; this is the iOS analogue.
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
        /// (for example E2B's `e2b-traffic-access-token`). Empty when the
        /// backend authorizes purely by token (Freestyle); preserved so the
        /// WebSocket transport can replay them verbatim.
        public let headers: [String: String]
        public let token: String
        /// The lease session id. The cmuxd-remote handshake authenticates with
        /// `{ type: "auth", token, session_id }`, so the transport needs this
        /// alongside the token — it is not optional context.
        public let sessionID: String
        /// Lease expiry as a Unix timestamp in **seconds** (the backend stores
        /// `new Date(expiresAtUnix * 1000)`); see ``expiresAt``.
        public let expiresAtUnix: Double

        /// The lease expiry as a `Date`, or `nil` for a missing / non-positive
        /// value so a malformed `0` is treated as non-expiring rather than
        /// pinned to the 1970 epoch (which would read as instantly expired).
        public var expiresAt: Date? {
            guard expiresAtUnix.isFinite, expiresAtUnix > 0 else {
                return nil
            }
            return Date(timeIntervalSince1970: expiresAtUnix)
        }

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

/// Decodes the backend Cloud VM attach-endpoint response into a
/// ``CmxCloudAttachEndpoint``, the cloud-route counterpart to
/// ``CmxPairingQRCode`` (issue #6700).
public struct CmxCloudAttach: Sendable {
    /// The transport label the backend uses for a cmuxd-remote WebSocket
    /// endpoint (`web/services/vms/drivers/types.ts`).
    public static let webSocketTransport = "websocket"

    /// Creates the codec. It is stateless: construct one inline at the call
    /// site.
    public init() {}

    /// Decode a `POST /api/vm/{id}/attach-endpoint` response body into a
    /// ``CmxCloudAttachEndpoint``.
    ///
    /// The transport is probed first so an SSH fallback (a differently-shaped
    /// endpoint the phone can't dial) surfaces as a typed
    /// ``CmxCloudAttachError/unsupportedTransport(_:)`` error rather than an
    /// opaque `DecodingError` from the WebSocket-shaped decode. One decoder is
    /// reused across both passes.
    ///
    /// - Parameter data: The raw JSON response body.
    /// - Throws: ``CmxCloudAttachError/unsupportedTransport(_:)`` for a
    ///   non-WebSocket endpoint, or a `DecodingError` for a malformed payload.
    public func decode(_ data: Data) throws -> CmxCloudAttachEndpoint {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(CmxCloudAttachTransportProbe.self, from: data)
        guard probe.transport == Self.webSocketTransport else {
            throw CmxCloudAttachError.unsupportedTransport(probe.transport)
        }
        return try decoder.decode(CmxCloudAttachEndpoint.self, from: data)
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
