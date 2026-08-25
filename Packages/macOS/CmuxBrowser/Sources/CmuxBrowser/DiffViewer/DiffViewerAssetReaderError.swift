/// Errors specific to bounded diff-viewer asset admission.
public enum DiffViewerAssetReaderError: Error, Equatable, Sendable {
    /// The reader already has one active stream and its bounded waiting queue is full.
    case capacityExceeded
}
