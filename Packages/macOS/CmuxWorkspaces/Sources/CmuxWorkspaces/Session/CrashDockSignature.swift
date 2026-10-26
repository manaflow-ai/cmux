public import Foundation

/// The persisted panel and agent identities of a dock during crash recovery.
///
/// Docks have one layout slot. Different docks stay separate rather than
/// choosing a layout that could discard the other copy's panels.
public struct CrashDockSignature: Equatable, Sendable {
    public let panelIDs: Set<UUID>
    public let checkpointIDs: Set<String>

    /// Captures all panels and agent checkpoints in one dock.
    /// - Parameters:
    ///   - panelIDs: Persisted identities of every dock panel, including nonterminals.
    ///   - checkpointIDs: Agent checkpoints belonging to the dock's terminals.
    public nonisolated init(panelIDs: Set<UUID>, checkpointIDs: Set<String>) {
        self.panelIDs = panelIDs
        self.checkpointIDs = checkpointIDs
    }
}
