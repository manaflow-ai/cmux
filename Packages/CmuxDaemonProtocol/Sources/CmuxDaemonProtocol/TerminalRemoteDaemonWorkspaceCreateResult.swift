public import Foundation

/// The result of creating a workspace via ``DaemonRPCMethod/workspaceCreate``.
///
/// The daemon mints the workspace identifier and reports the change sequence at
/// which the workspace became visible.
public struct TerminalRemoteDaemonWorkspaceCreateResult: Decodable, Equatable, Sendable {
    /// The newly minted workspace identifier.
    public let workspaceID: String
    /// The daemon change sequence at which the workspace was created.
    public let changeSeq: UInt64

    /// Creates a workspace-create result value.
    /// - Parameters:
    ///   - workspaceID: The newly minted workspace identifier.
    ///   - changeSeq: The change sequence at which the workspace was created.
    public init(workspaceID: String, changeSeq: UInt64) {
        self.workspaceID = workspaceID
        self.changeSeq = changeSeq
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case changeSeq = "change_seq"
    }
}
