import Foundation

/// Metadata for a native text-input request accepted by the Simulator pane.
public struct SimulatorTextInputSubmission: Equatable, Sendable {
    /// Correlates cancellation with the queued worker message.
    public let requestIdentifier: UUID
    /// The number of user-visible characters submitted.
    public let characterCount: Int
    /// The maximum interval callers should wait for correlated worker receipt.
    public let completionTimeoutSeconds: TimeInterval

    /// Creates metadata for an accepted text-input request.
    public init(
        requestIdentifier: UUID,
        characterCount: Int,
        completionTimeoutSeconds: TimeInterval
    ) {
        self.requestIdentifier = requestIdentifier
        self.characterCount = characterCount
        self.completionTimeoutSeconds = completionTimeoutSeconds
    }
}
