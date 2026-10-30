public import Foundation

/// Writes to a PTY. `bytes` travels as standard base64.
public struct SendInputRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "send"
    public var surface: SurfaceID
    public var text: String?
    public var bytes: Data?
    public var paste: Bool?
    /// `send-expect-foreground-v1`: the daemon writes only while the terminal's foreground
    /// executable is still this one (``TerminalProcessInfoRequest``'s `foregroundExecutable`), checked
    /// right before the write, and fails the request otherwise. A daemon without the capability
    /// ignores it, so a caller keeps its own check first.
    public var expectForeground: String?
    /// The key press this input carries (`CMUX_NEXT_TRACE_FLOWS`, `TypingLatencyProbe.openFlow(for:)`): the daemon
    /// only records it in its flow marks. Nil (left out of the line) otherwise; an older daemon ignores it.
    public var flow: UInt64?
    public init(surface: SurfaceID, text: String? = nil, bytes: Data? = nil, paste: Bool? = nil,
                expectForeground: String? = nil, flow: UInt64? = nil) {
        self.surface = surface
        self.text = text
        self.bytes = bytes
        self.paste = paste
        self.expectForeground = expectForeground
        self.flow = flow
    }
}

/// Writes to a terminal by its host id, also one still being created
/// (`terminal-input-while-creating-v1`): the daemon queues input for a creating terminal and
/// writes it after the commit, before any later input. Bytes it cannot write come back in one
/// ``TerminalInputUnclaimed`` event on this connection.
public struct SendTerminalInputRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// True when the terminal was still being created: the bytes wait in the daemon.
        public var queued: Bool?
    }
    public static let command = "send"
    public var terminalID: String
    public var bytes: Data
    public init(terminalID: String, bytes: Data) {
        self.terminalID = terminalID
        self.bytes = bytes
    }
}

/// Bytes the daemon queued for a terminal that was being created and did not write
/// (`terminal-input-while-creating-v1`), sent to the connection that queued them. The client
/// gives them to the terminal that has focus.
public struct TerminalInputUnclaimed: Decodable, Sendable, Equatable {
    /// The event name (one place, so the protocol name can change here only).
    public static let eventName = "terminal-input-unclaimed"
    public var terminalId: String
    public var bytesBase64: String
    /// `failed`, `cancelled`, `expired` or `write-failed`.
    public var reason: String
    public var bytes: Data? { Data(base64Encoded: bytesBase64) }
    /// The give-back in `event`, a side event of the control connection; nil for any other event.
    public init?(_ event: DaemonEvent) {
        guard case .unknown(let name, let payload) = event, name == Self.eventName,
              let terminalID = payload["terminal_id"]?.stringValue,
              let bytesBase64 = payload["bytes_base64"]?.stringValue else { return nil }
        self.terminalId = terminalID
        self.bytesBase64 = bytesBase64
        reason = payload["reason"]?.stringValue ?? ""
    }
    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", bytesBase64 = "bytes_base64", reason
    }
}

public struct SendKeyRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "send-key"
    public var surface: SurfaceID
    public var keys: [String]
    public init(surface: SurfaceID, keys: [String]) {
        self.surface = surface
        self.keys = keys
    }
}

public struct AttachSurfaceRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var lease: String?
        /// This view's sizing participant and the terminal's size state, for a connection that
        /// lists `shared-sizing-v1`.
        public var participant: String?
        public var sizeState: TerminalSizeState?
        enum CodingKeys: String, CodingKey {
            case lease, participant
            case sizeState = "size_state"
        }
    }
    public static let command = "attach-surface"
    public var surface: SurfaceID?
    public var expectedGeneration: DaemonGeneration?
    /// The public terminal id `term_…` (a tab's `terminal_resource_id`).
    public var expectedTerminalID: ResourceID?
    public var mode: String
    public var cols: Int?
    public var rows: Int?
    /// `ghostsnp` asks for snapshots (`terminal-snapshot-v1`) when the
    /// host's GHOSTSNP version equals `snapshotVersion`; any other version
    /// gets the byte replay.
    public var snapshot: String?
    public var snapshotVersion: UInt16?
    /// The view restores local-history READYs at a resize
    /// (`terminal-snapshot-local-history-v1`).
    public var snapshotLocalHistory: Bool?
    /// The view applies Kitty image replays (`terminal-snapshot-images-v1`).
    public var snapshotImages: Bool?

    /// - Parameter snapshotVersion: the viewer's GHOSTSNP version, or nil for
    ///   a byte replay.
    public init(surface: SurfaceID?, expectedGeneration: DaemonGeneration? = nil, expectedTerminalID: ResourceID? = nil,
                size: CellSize?, snapshotVersion: UInt16? = nil, snapshotLocalHistory: Bool = false,
                snapshotImages: Bool = false) {
        self.surface = surface
        self.expectedGeneration = expectedGeneration
        self.expectedTerminalID = expectedTerminalID
        self.mode = "bytes"
        self.cols = size?.cols
        self.rows = size?.rows
        self.snapshot = snapshotVersion == nil ? nil : "ghostsnp"
        self.snapshotVersion = snapshotVersion
        self.snapshotLocalHistory = snapshotVersion != nil && snapshotLocalHistory ? true : nil
        self.snapshotImages = snapshotVersion != nil && snapshotImages ? true : nil
    }
}
