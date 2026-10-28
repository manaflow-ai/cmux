public import Foundation

/// The persisted panel and agent identities of a dock during crash recovery.
///
/// Docks have one layout slot. Different docks stay separate rather than
/// choosing a layout that could discard the other copy's panels.
public struct CrashDockSignature: Equatable, Sendable {
    /// IDs of every panel persisted in this dock.
    public let panelIDs: Set<UUID>
    /// Agent checkpoints belonging to dock terminals.
    public let checkpointIDs: Set<String>
    /// Fingerprint of the complete persisted dock, or nil when it cannot be compared safely.
    public let contentFingerprint: String?

    /// Captures all panels and agent checkpoints in one dock.
    /// - Parameters:
    ///   - panelIDs: Persisted identities of every dock panel, including nonterminals.
    ///   - checkpointIDs: Agent checkpoints belonging to the dock's terminals.
    ///   - contentFingerprint: A deterministic digest of the complete persisted dock.
    public nonisolated init(panelIDs: Set<UUID>, checkpointIDs: Set<String>, contentFingerprint: String? = nil) {
        self.panelIDs = panelIDs
        self.checkpointIDs = checkpointIDs
        self.contentFingerprint = contentFingerprint
    }
}
