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
    public static let requiredCapability: String? = DaemonCapability.remoteTerminalTabs.rawValue
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
extension UpdateRemoteTerminalTabRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var changed: Bool
    }
    /// The daemon's bound on `snapshot` (UTF-8 bytes).
    public static let snapshotLimit = 65_536

    /// The last `limit` bytes of `text`, cut at a line start when one is
    /// near and never inside a UTF-8 sequence.
    public static func bounded(_ text: String, limit: Int = snapshotLimit) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        // Skip continuation bytes so the cut never lands inside a sequence.
        var tail = bytes.suffix(limit).drop { $0 & 0xC0 == 0x80 }
        if let newline = tail.prefix(4096).firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: newline)) }
        return String(decoding: tail, as: UTF8.self)
    }
}

/// `remote-terminal-snapshot`: the stored placeholder snapshot of a tab.
extension RemoteTerminalSnapshotRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var snapshot: String?
    }
}
