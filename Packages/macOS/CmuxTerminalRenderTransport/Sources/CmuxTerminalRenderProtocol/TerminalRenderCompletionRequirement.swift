public import Foundation

/// Completion mechanism accepted by one host presentation generation.
public enum TerminalRenderCompletionRequirement: Equatable, Sendable {
    /// Accept only surfaces published from the producer's completion callback.
    case producerCompleted

    /// Accept only values from one imported shared Metal event.
    case sharedEvent(eventID: UUID, minimumValue: UInt64)

}
