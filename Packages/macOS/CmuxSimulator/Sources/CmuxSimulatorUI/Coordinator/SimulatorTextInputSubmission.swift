import Foundation

/// Metadata for a native text-input request accepted by the Simulator pane.
public struct SimulatorTextInputSubmission: Equatable, Sendable {
    /// The number of user-visible characters submitted.
    public let characterCount: Int
    /// The maximum interval callers should wait for correlated worker receipt.
    public let completionTimeoutSeconds: TimeInterval

    /// Creates metadata for an accepted text-input request.
    public init(characterCount: Int, completionTimeoutSeconds: TimeInterval) {
        self.characterCount = characterCount
        self.completionTimeoutSeconds = completionTimeoutSeconds
    }
}
