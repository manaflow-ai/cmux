import Foundation

/// Provides a manually advanced deterministic replica clock for tests and previews.
public final class ManualReplicaClock: ReplicaClock {
    /// The current tick returned by ``tick()``.
    public var currentTick: Int

    /// Creates a manual clock.
    /// - Parameter currentTick: The initial tick returned by ``tick()``.
    public init(currentTick: Int) {
        self.currentTick = currentTick
    }

    /// Returns the configured tick.
    /// - Returns: The configured integer tick.
    public func tick() -> Int {
        currentTick
    }

    /// Advances the clock by a deterministic number of ticks.
    /// - Parameter amount: The number of ticks to add.
    public func advance(by amount: Int = 1) {
        currentTick += amount
    }
}
