public import Foundation

/// Persisted per-command usage stats backing the recency/frequency boost.
public struct CommandPaletteUsageEntry: Codable, Sendable {
    /// Total times the command was run.
    public var useCount: Int
    /// Unix timestamp of the most recent run.
    public var lastUsedAt: TimeInterval

    /// Creates a usage entry.
    public init(useCount: Int, lastUsedAt: TimeInterval) {
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}
