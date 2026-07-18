import CmuxTerminalBackend
import Foundation

/// Stable-identity requests for daemon-committed terminal topology changes.
protocol TerminalBackendTopologyMutating: Sendable {
    func createWorkspace(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func createTerminalTab(
        requestID: UUID,
        surfaceID: SurfaceID,
        in paneID: PaneID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func createBrowserWorkspace(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func createBrowserTab(
        requestID: UUID,
        surfaceID: SurfaceID,
        in paneID: PaneID,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func splitBrowserPane(
        requestID: UUID,
        surfaceID: SurfaceID,
        _ paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    /// Materializes a daemon-owned terminal with caller-stable identities in
    /// the active pane of an existing canonical workspace.
    func materializeTerminal(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    /// Atomically replaces one terminal runtime while preserving its stable
    /// surface UUID and canonical placement.
    func respawnTerminal(
        requestID: UUID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func materializeExternalTerminal(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool
    ) async throws -> BackendSurfacePlacement

    func splitPane(
        requestID: UUID,
        surfaceID: SurfaceID,
        _ paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement

    func splitTab(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        around paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement

    func closePane(requestID: UUID, _ paneID: PaneID) async throws -> BackendTopologyMutationReceipt
    func closeWorkspace(
        requestID: UUID,
        _ workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt
    func renameWorkspace(
        requestID: UUID,
        _ workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt
    func renameSurface(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt
    func moveTab(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        to paneID: PaneID,
        index: Int
    ) async throws -> BackendTopologyMutationReceipt
    func reorderTabs(
        requestID: UUID,
        in paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt
    func reorderWorkspaces(
        requestID: UUID,
        _ workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt

    func moveTabToNewWorkspace(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String?,
        index: Int?
    ) async throws -> BackendSurfacePlacement

    func setSplitRatio(
        requestID: UUID,
        around paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt
}

/// Ordered connection-owned bridge between an external PTY producer and one
/// daemon-owned parser/render runtime.
protocol TerminalBackendExternalTerminalServing: Sendable {
    func claimExternalTerminal(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendExternalTerminalClaimReceipt

    func resetExternalTerminal(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        columns: UInt16,
        rows: UInt16,
        seed: Data
    ) async throws -> BackendExternalTerminalOutputReceipt

    func sendExternalTerminalOutput(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        sequence: UInt64,
        data: Data
    ) async throws -> BackendExternalTerminalOutputReceipt

    func drainExternalTerminalEgress(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64
    ) async throws -> Data
}
