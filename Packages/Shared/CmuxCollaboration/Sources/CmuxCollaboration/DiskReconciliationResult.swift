public import Foundation

/// The outcome of writing a resolved collaboration document back to disk.
public enum DiskReconciliationResult: Equatable, Sendable {
    /// The resolved CRDT text was written to the original file.
    case wroteOriginal(fileURL: URL, textHash: String)
    /// The original changed out-of-band, so the CRDT text was written beside it.
    case wroteConflict(originalURL: URL, conflictURL: URL, originalHash: String, collaborationHash: String)
}
