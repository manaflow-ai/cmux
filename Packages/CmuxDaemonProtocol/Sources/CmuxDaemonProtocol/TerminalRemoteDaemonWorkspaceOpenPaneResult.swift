public import Foundation

/// The result of opening a pane via ``DaemonRPCMethod/workspaceOpenPane``.
///
/// The daemon mints both the session and pane identifiers for a fresh shell in
/// the given workspace. This is the canonical way clients obtain a session
/// identifier without inventing one.
public struct TerminalRemoteDaemonWorkspaceOpenPaneResult: Decodable, Equatable, Sendable {
    /// The workspace the pane was opened in.
    public let workspaceID: String
    /// The newly minted pane identifier.
    public let paneID: String
    /// The newly minted session identifier.
    public let sessionID: String
    /// The attachment identifier for this client.
    public let attachmentID: String
    /// The initial read offset.
    public let offset: UInt64
    /// The effective column count the daemon renders at.
    public let effectiveCols: Int
    /// The effective row count the daemon renders at.
    public let effectiveRows: Int
    /// See ``TerminalRemoteDaemonSessionStatus/gridGeneration``.
    public let gridGeneration: UInt64?

    /// Creates a workspace open-pane result value.
    /// - Parameters:
    ///   - workspaceID: The workspace the pane was opened in.
    ///   - paneID: The newly minted pane identifier.
    ///   - sessionID: The newly minted session identifier.
    ///   - attachmentID: The attachment identifier for this client.
    ///   - offset: The initial read offset.
    ///   - effectiveCols: The effective column count.
    ///   - effectiveRows: The effective row count.
    ///   - gridGeneration: The monotonic grid-change counter, if reported.
    public init(
        workspaceID: String,
        paneID: String,
        sessionID: String,
        attachmentID: String,
        offset: UInt64,
        effectiveCols: Int,
        effectiveRows: Int,
        gridGeneration: UInt64? = nil
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.offset = offset
        self.effectiveCols = effectiveCols
        self.effectiveRows = effectiveRows
        self.gridGeneration = gridGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case offset
        case effectiveCols = "effective_cols"
        case effectiveRows = "effective_rows"
        case gridGeneration = "grid_generation"
    }
}
