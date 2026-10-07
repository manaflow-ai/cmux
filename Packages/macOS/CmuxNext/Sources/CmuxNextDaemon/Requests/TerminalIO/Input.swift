public import Foundation

/// Writes to a PTY. `bytes` travels as standard base64.
public struct SendInputRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "send"
    public var surface: SurfaceID
    public var text: String?
    public var bytes: Data?
    public var paste: Bool?
    public init(surface: SurfaceID, text: String? = nil, bytes: Data? = nil, paste: Bool? = nil) {
        self.surface = surface
        self.text = text
        self.bytes = bytes
        self.paste = paste
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
