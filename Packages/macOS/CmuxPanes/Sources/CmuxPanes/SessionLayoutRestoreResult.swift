import Foundation

/// A rebuilt subtree and the emptiness carried through iterative assembly.
struct SessionLayoutRestoreResult {
    let layout: SessionWorkspaceLayoutSnapshot
    let isEmpty: Bool
    let panelIDs: Set<UUID>
}
