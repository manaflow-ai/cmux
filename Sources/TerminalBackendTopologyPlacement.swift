import Foundation

/// One stable terminal placement admitted by the daemon topology authority.
struct TerminalBackendTopologyPlacement: Hashable, Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
}
