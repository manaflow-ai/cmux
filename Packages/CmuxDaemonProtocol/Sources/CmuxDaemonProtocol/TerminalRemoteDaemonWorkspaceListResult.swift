public import Foundation

/// The set of workspaces the daemon currently knows about.
///
/// Returned by ``DaemonRPCMethod/workspaceList`` and ``DaemonRPCMethod/workspaceSubscribe``,
/// and carried in workspace push snapshots. The ``changeSeq`` lets clients
/// discard stale snapshots that arrive out of order.
public struct TerminalRemoteDaemonWorkspaceListResult: Decodable, Equatable, Sendable {
    /// The workspaces, in daemon-defined order.
    public let workspaces: [TerminalRemoteDaemonWorkspaceEntry]
    /// The currently selected workspace, if any.
    public let selectedWorkspaceID: String?
    /// The daemon change sequence this snapshot reflects.
    public let changeSeq: UInt64

    /// Creates a workspace-list result value.
    /// - Parameters:
    ///   - workspaces: The workspaces, in daemon-defined order.
    ///   - selectedWorkspaceID: The selected workspace, if any.
    ///   - changeSeq: The daemon change sequence this snapshot reflects.
    public init(
        workspaces: [TerminalRemoteDaemonWorkspaceEntry],
        selectedWorkspaceID: String? = nil,
        changeSeq: UInt64
    ) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.changeSeq = changeSeq
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case selectedWorkspaceID = "selected_workspace_id"
        case changeSeq = "change_seq"
    }
}
