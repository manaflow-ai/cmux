import Foundation

/// `new-remote-terminal-tab`: a remote-terminal tab in `pane` (default: the
/// active pane of the active workspace).
public struct NewRemoteTerminalTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var tabResourceID: ResourceID?
        enum CodingKeys: String, CodingKey {
            case surface
            case tabResourceID = "tab_resource_id"
        }
    }
    public static let command = "new-remote-terminal-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.remoteTerminalTabs
    public var pane: PaneID?
    public var sessionID: String
    public var terminalID: TerminalID
    public var sessionName: String
    public var title: String?
    public var cols: Int?
    public var rows: Int?

    public init(_ ref: RemoteTerminalRef, pane: PaneID? = nil, title: String? = nil, size: CellSize? = nil) {
        self.pane = pane
        sessionID = ref.sessionID
        terminalID = ref.terminalID
        sessionName = ref.sessionName
        self.title = title
        cols = size?.cols
        rows = size?.rows
    }
}

/// `update-remote-terminal-tab`: the last title, session name and bounded
/// text snapshot the placeholder shows while the session is unavailable.
public struct UpdateRemoteTerminalTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var changed: Bool
    }
    public static let command = "update-remote-terminal-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.remoteTerminalTabs
    /// The daemon's bound on `snapshot` (UTF-8 bytes).
    public static let snapshotLimit = 65_536
    public var surface: SurfaceID
    public var title: FieldUpdate<String>
    public var sessionName: String?
    public var snapshot: FieldUpdate<String>

    public init(surface: SurfaceID, title: FieldUpdate<String> = .unchanged, sessionName: String? = nil,
                snapshot: FieldUpdate<String> = .unchanged) {
        self.surface = surface
        self.title = title
        self.sessionName = sessionName
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey { case surface, title, sessionName, snapshot }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(sessionName, forKey: .sessionName)
        try c.encode(snapshot, forKey: .snapshot)
    }

    /// The last `limit` bytes of `text`, cut at a line start when one is
    /// near and never inside a UTF-8 sequence.
    public static func bounded(_ text: String, limit: Int = snapshotLimit) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        var start = bytes.count - limit
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        if let newline = bytes[start...].prefix(4096).firstIndex(of: 0x0A) { start = newline + 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}

/// `remote-terminal-snapshot`: the stored placeholder snapshot of a tab.
public struct RemoteTerminalSnapshotRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var snapshot: String?
    }
    public static let command = "remote-terminal-snapshot"
    public static let requiredCapability: String? = DaemonCapabilities.shared.remoteTerminalTabs
    public var surface: SurfaceID

    public init(surface: SurfaceID) { self.surface = surface }
}
