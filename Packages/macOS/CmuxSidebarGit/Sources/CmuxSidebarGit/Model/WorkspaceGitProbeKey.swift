import Foundation

/// Identity of one sidebar git probe: a panel within a workspace.
///
/// Every piece of per-panel tracking state in both services (probe state,
/// tracked directory, watcher, PR poll deadline) is keyed by this pair.
struct WorkspaceGitProbeKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}
