import Foundation

/// Supplies deterministic display ticks to replica stores.
public protocol ReplicaClock: AnyObject {
    /// Returns the current display tick.
    /// - Returns: A deterministic integer tick.
    func tick() -> Int
}
