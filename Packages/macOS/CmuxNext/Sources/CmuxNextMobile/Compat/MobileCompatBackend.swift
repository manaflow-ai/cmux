public import CmuxNextDaemon
public import Foundation

/// What the compat adapter needs from the daemon. The live implementation is
/// `DaemonCompatBackend`; tests use an in-memory fake.
public protocol MobileCompatBackend: Sendable {
    func tree() async throws -> DaemonTree
    /// Yields once per tree mutation, until the subscriber stops iterating.
    func treeChanges() -> AsyncStream<Void>
    func createWorkspace(name: String?) async throws -> WorkspaceKey
    func renameWorkspace(_ key: WorkspaceKey, to name: String) async throws
    func closeWorkspace(_ key: WorkspaceKey) async throws
    func createTerminal(in key: WorkspaceKey, cwd: String?) async throws -> TerminalID?
    func send(_ surface: SurfaceID, bytes: Data, paste: Bool) async throws
    func renameTab(_ surface: SurfaceID, to name: String) async throws
    func closeTerminal(_ terminal: TerminalID) async throws
    /// Opens a dedicated byte-mode attachment (vt-state then live output).
    func attach(_ tab: TabSnapshot, generation: DaemonGeneration?, size: CellSize) async throws
        -> any MobileCompatTerminalChannel
}

/// One phone view of one terminal. Every call is fire-and-forget after the
/// attach handshake, like the Mac's own terminal views.
public protocol MobileCompatTerminalChannel: Sendable {
    var events: AsyncStream<TerminalChannelEvent> { get }
    func resize(cols: Int, rows: Int) async
    func claimGeometry() async
    func releaseGeometry() async
    func detach() async
}

extension TerminalAttachment: MobileCompatTerminalChannel {
    public func resize(cols: Int, rows: Int) async {
        await resize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }
}
