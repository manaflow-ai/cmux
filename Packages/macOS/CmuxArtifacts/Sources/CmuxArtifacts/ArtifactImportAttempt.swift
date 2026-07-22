import Foundation

/// Store result for one candidate in a batch import.
public enum ArtifactImportAttempt: Equatable, Sendable {
    /// The candidate produced an observable import outcome.
    case imported(ArtifactImportOutcome)
    /// The candidate failed repository validation.
    case rejected(ArtifactStoreError)
}
