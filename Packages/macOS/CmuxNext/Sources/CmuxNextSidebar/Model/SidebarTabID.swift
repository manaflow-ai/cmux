import Foundation

/// Stable identifier for a tab shown beneath a workspace row.
public nonisolated struct TabID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}
