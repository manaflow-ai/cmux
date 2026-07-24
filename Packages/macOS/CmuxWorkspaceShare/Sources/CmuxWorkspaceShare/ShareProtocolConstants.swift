/// Stable constants for the cmux workspace-share wire protocol.
public struct ShareProtocolConstants: Sendable {
    /// Current JSON protocol version.
    public static let version = 1

    /// Binary-frame kind for terminal render-grid payloads.
    public static let binaryKindGrid: UInt8 = 0x01

    /// Host JSON frames must contain fewer than this many encoded UTF-8 bytes.
    public static let maximumHostJSONFrameBytes = 64 * 1_024

    /// Server JSON frames must contain fewer than this many encoded UTF-8 bytes.
    public static let serverJSONFrameByteLimit = 1_024 * 1_024

    /// Oversized WebSocket messages are closed with RFC 6455 code 1009.
    public static let messageTooBigCloseCode = 1_009

    /// Complete binary render-grid frames must contain fewer than this many bytes.
    public static let binaryFrameByteLimit = 1_024 * 1_024

    /// A share session exposes at most one workspace.
    public static let maximumSharedWorkspaces = 1

    /// Maximum pane leaves in a workspace layout.
    public static let maximumLayoutPanes = 128

    /// Maximum recursive depth in a workspace layout.
    public static let maximumLayoutDepth = 16

    /// Maximum UTF-8 byte count for opaque wire identifiers.
    public static let maximumIDBytes = 256

    /// Maximum UTF-8 byte count for an identity email.
    public static let maximumEmailBytes = 320

    /// Maximum UTF-8 byte count for a workspace or pane title.
    public static let maximumTitleBytes = 512

    /// Maximum retained chat messages in a session snapshot.
    public static let maximumChatMessages = 500

    /// Maximum UTF-8 byte count for one chat message.
    public static let maximumChatTextBytes = 4_000

    /// The worker can retain 256 guest grants plus the host.
    public static let maximumParticipants = 257

    /// Maximum simultaneously pending access requests.
    public static let maximumPendingAccessRequests = 16

    /// Maximum active sockets, including the host.
    public static let maximumConnections = 32

    /// Maximum UTF-8 byte count for one guest terminal-input request.
    public static let maximumTerminalInputBytes = 16 * 1_024

    private init() {}
}
