public import Foundation

/// The daemon's handshake response describing the connected `cmuxd-remote` instance.
///
/// Returned by the ``DaemonRPCMethod/hello`` RPC and also emitted as the
/// connection's first line so clients can identify the daemon, its capabilities,
/// and its current change sequence before issuing any further requests.
public struct TerminalRemoteDaemonHello: Decodable, Equatable, Sendable {
    /// The daemon's product name.
    public let name: String
    /// The daemon's version string.
    public let version: String
    /// The daemon instance identifier, if reported.
    public let instanceID: String?
    /// The number of workspaces the daemon currently knows about, if reported.
    public let workspaceCount: Int?
    /// The daemon's current monotonic change sequence, if reported.
    public let changeSeq: UInt64?
    /// The capability tokens the daemon advertises.
    public let capabilities: [String]

    /// Creates a handshake value.
    /// - Parameters:
    ///   - name: The daemon's product name.
    ///   - version: The daemon's version string.
    ///   - instanceID: The daemon instance identifier, if known.
    ///   - workspaceCount: The known workspace count, if reported.
    ///   - changeSeq: The daemon's change sequence, if reported.
    ///   - capabilities: The advertised capability tokens.
    public init(
        name: String,
        version: String,
        instanceID: String?,
        workspaceCount: Int? = nil,
        changeSeq: UInt64? = nil,
        capabilities: [String]
    ) {
        self.name = name
        self.version = version
        self.instanceID = instanceID
        self.workspaceCount = workspaceCount
        self.changeSeq = changeSeq
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case instanceID = "instance_id"
        case workspaceCount = "workspace_count"
        case changeSeq = "change_seq"
        case capabilities
    }
}
