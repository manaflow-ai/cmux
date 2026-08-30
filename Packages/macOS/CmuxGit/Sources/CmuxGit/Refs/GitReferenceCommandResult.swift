import Foundation

/// Classifies one bounded Git command without conflating a missing ref with I/O failure.
nonisolated enum GitReferenceCommandResult: Equatable, Sendable {
    case value(String)
    case missing
    case failed
}
