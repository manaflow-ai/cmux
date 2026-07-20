/// Pure ordering policy for cross-process frames.
public enum RendererFrameAcceptance {
    /// Accepts only frames from the current worker generation whose sequence
    /// is newer than the last displayed frame.
    public static func accepts(
        _ candidate: RendererFrameMetadata,
        currentGeneration: UInt64,
        lastAccepted: RendererFrameMetadata?
    ) -> Bool {
        guard candidate.identity.generation == currentGeneration else { return false }
        guard let lastAccepted,
              lastAccepted.identity.generation == candidate.identity.generation else {
            return true
        }
        return candidate.sequence > lastAccepted.sequence
    }
}
