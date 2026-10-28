/// Complete comparison evidence for one pane of an agent session.
///
/// A checkpoint can appear in several panes. Keep each observation separate so
/// replacing a workspace preserves both pane multiplicity and content ownership.
public struct CrashAgentPanelSignature: Equatable, Sendable {
    let checkpointID: String
    let metadataFingerprint: String
    let contentFingerprints: Set<String>

    /// Captures one pane after excluding only runtime identity and recovered directories.
    /// - Parameters:
    ///   - checkpointID: The agent session shown by this pane.
    ///   - metadataFingerprint: Exact normalized persisted pane metadata.
    ///   - contentFingerprints: Exact optional text and resume payloads; absent payloads add nothing.
    public nonisolated init(
        checkpointID: String, metadataFingerprint: String, contentFingerprints: Set<String>
    ) {
        self.checkpointID = checkpointID
        self.metadataFingerprint = metadataFingerprint
        self.contentFingerprints = contentFingerprints
    }

    nonisolated func contains(_ other: Self) -> Bool {
        checkpointID == other.checkpointID && metadataFingerprint == other.metadataFingerprint
            && contentFingerprints.isSuperset(of: other.contentFingerprints)
    }
}
