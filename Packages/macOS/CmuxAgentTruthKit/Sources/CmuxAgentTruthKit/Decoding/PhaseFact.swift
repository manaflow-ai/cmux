import Foundation

/// Captures transcript-derived phase corroboration facts.
public enum PhaseFact: Hashable, Sendable {
    /// A turn was aborted at the given transcript line.
    case turnAborted(line: Int)
    /// A task started at the given transcript line.
    case taskStarted(line: Int)
    /// A task completed at the given transcript line.
    case taskCompleted(line: Int)
}
