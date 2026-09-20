/// A Mac workspace's authoritative pane layout, independent of mobile state sync.
public struct DeviceWorkspaceLayoutSnapshot: Codable, Equatable, Sendable {
    /// The stable workspace ID on the owning Mac.
    public let workspaceID: String
    /// The ordered pane tree and divider proportions on the owning Mac.
    public let layout: DeviceWorkspaceLayoutNode
    /// Opaque owning-Mac revision used to reject edits based on an older layout.
    /// An empty value identifies an older peer that supports read-only snapshots.
    public let revision: String
    /// Monotonic workspace sequence within the current owning-Mac connection.
    public let sequence: UInt64

    /// Creates a snapshot for one Mac workspace.
    /// - Parameters:
    ///   - workspaceID: The owning Mac's stable workspace ID.
    ///   - layout: Its current pane tree.
    ///   - revision: The owning Mac's revision, or empty for a read-only legacy peer.
    ///   - sequence: Ordering fence for event/reply races, reset on reconnect.
    public init(workspaceID: String, layout: DeviceWorkspaceLayoutNode, revision: String = "", sequence: UInt64 = 0) {
        self.workspaceID = workspaceID
        self.layout = layout
        self.revision = revision
        self.sequence = sequence
    }

    /// Decodes current snapshots and older Mac peers without revision support.
    /// - Parameter decoder: The encoded Mac workspace snapshot.
    /// - Throws: A decoding error for malformed workspace or layout fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        layout = try values.decode(DeviceWorkspaceLayoutNode.self, forKey: .layout)
        revision = try values.decodeIfPresent(String.self, forKey: .revision) ?? ""
        sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case layout
        case revision
        case sequence
    }
}
