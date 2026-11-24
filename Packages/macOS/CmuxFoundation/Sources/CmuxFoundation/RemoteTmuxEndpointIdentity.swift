/// What makes one remote tmux endpoint distinct from another, and the hash cmux keys it by.
///
/// The hash names the shared ssh master's socket and keys every per-endpoint table (transports,
/// control connections, mirrors), so two identities that differ must hash differently and one
/// identity must hash the same way every time. That separation is a safety property: the
/// master multiplexes destructive commands (`kill-session`, `rename-window`), so two endpoints
/// must never collapse onto one socket and route a command to the wrong server.
///
/// Launch-only route settings (a broker, a helper path) are not part of identity. A live
/// endpoint has one route, and a conflicting launch setting is rejected rather than opening a
/// second connection.
///
/// ```swift
/// let identity = RemoteTmuxEndpointIdentity(destination: "dev@host", socketName: "alpha")
/// let key = identity.connectionHash
/// ```
public struct RemoteTmuxEndpointIdentity: Sendable, Equatable {
    /// A transport other than plain ssh, with the port it resolves to.
    ///
    /// The port is the resolved one, not the configured one: an unset port and the explicit
    /// default it resolves to are one endpoint and must be one key.
    public struct Transport: Sendable, Equatable {
        /// The transport's stable name, such as `et`.
        public let name: String
        /// The port the transport actually uses.
        public let resolvedPort: Int

        /// Creates a transport component from its stable name and resolved port.
        public init(name: String, resolvedPort: Int) {
            self.name = name
            self.resolvedPort = resolvedPort
        }
    }

    /// The ssh destination, case-sensitive, as the user gave it.
    public let destination: String
    /// The explicit ssh port, or `nil` for ssh's own default.
    public let port: Int?
    /// The explicit identity file, or `nil` for ssh's own choice.
    public let identityFile: String?
    /// The control-stream transport when it is not plain ssh, otherwise `nil`.
    public let transport: Transport?
    /// The tmux server name (`tmux -L <name>`), or `nil` for the default server.
    public let socketName: String?

    /// Creates an identity. Only `destination` is required; the defaults describe plain ssh
    /// to the default tmux server.
    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        transport: Transport? = nil,
        socketName: String? = nil
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.transport = transport
        self.socketName = socketName
    }

    /// A stable, deterministic hex digest of this identity: FNV-1a/64 over a unit-separated
    /// fingerprint of the destination, port and identity file, then the transport and the
    /// socket name when they are set.
    ///
    /// The transport and socket name are appended only when set, so a plain ssh host on the
    /// default server keeps the hash it has always had. That hash names its master socket and
    /// persisted mirror state, and changing it would orphan both.
    public var connectionHash: String {
        var fingerprint = "\(destination)\u{1f}\(port.map(String.init) ?? "")\u{1f}\(identityFile ?? "")"
        if let transport {
            fingerprint += "\u{1f}\(transport.name)\u{1f}\(transport.resolvedPort)"
        }
        if let socketName {
            fingerprint += "\u{1f}socket\u{1f}\(socketName)"
        }
        return Self.fnv1a64Hex(fingerprint)
    }

    /// The FNV-1a 64-bit digest of `string`'s UTF-8 bytes, as 16 lowercase hex digits.
    ///
    /// A dependency-free short hash for deriving identifiers from a string; it is not a
    /// cryptographic hash.
    public static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
