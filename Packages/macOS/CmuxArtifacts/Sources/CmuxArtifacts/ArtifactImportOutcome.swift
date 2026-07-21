import Foundation

/// Observable result of one automatic or manual import attempt.
public enum ArtifactImportOutcome: Equatable, Sendable {
    /// A new ordinary file was copied into the artifact store.
    case copied(ArtifactRecord)
    /// Identical bytes already existed; provenance was recorded without another copy.
    case deduplicated(ArtifactRecord)
    /// The source already lived inside `.cmux/artifacts` and was recorded in place.
    case alreadyStored(ArtifactRecord)
    /// Policy rejected the candidate without mutating the store.
    case skipped(ArtifactSkipReason)

    /// The resulting artifact record, when a file was accepted.
    public var record: ArtifactRecord? {
        switch self {
        case .copied(let record), .deduplicated(let record), .alreadyStored(let record):
            return record
        case .skipped:
            return nil
        }
    }
}
