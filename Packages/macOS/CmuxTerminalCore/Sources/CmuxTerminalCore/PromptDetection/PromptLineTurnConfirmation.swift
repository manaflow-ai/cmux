import Foundation

/// A prompt-shaped boundary that must remain unchanged for a short confirmation delay.
public struct PromptLineTurnConfirmation: Equatable, Sendable {
    /// Monotonically increases per detector candidate, letting delivery
    /// owners confirm each boundary exactly once.
    public let identifier: UInt64

    let completedTurnCount: Int

    /// The debounce interval that must elapse before this boundary is confirmed.
    public let delay: Duration

    /// The completed turns represented by this boundary after confirmation.
    public var confirmedTurnCount: Int { completedTurnCount }

    init(identifier: UInt64, completedTurnCount: Int, delay: Duration) {
        self.identifier = identifier
        self.completedTurnCount = completedTurnCount
        self.delay = delay
    }
}
