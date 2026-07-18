import CmuxTerminalBackend
import Foundation

/// Canonical identity resolved by the daemon's idempotent ensure operation.
struct TerminalBackendTerminalBinding: Equatable, Sendable {
    let authority: BackendAuthority
    let appWorkspaceID: UUID
    let appSurfaceID: UUID
    let workspaceHandle: UInt64
    let workspaceID: WorkspaceID
    let surfaceHandle: UInt64
    let surfaceID: SurfaceID
    let columns: UInt16
    let rows: UInt16
    let created: Bool
}
