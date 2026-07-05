import Foundation

/// Identifies a configured Fleet loop.
public struct FleetID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The stable string value stored by callers.
    public let rawValue: String

    /// Creates a fleet identifier from its persisted string value.
    /// - Parameter rawValue: The stable fleet key.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fleet identifier from its persisted string value.
    /// - Parameter rawValue: The stable fleet key.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fleet identifier from a string literal.
    /// - Parameter value: The stable fleet key.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The display-neutral textual form of the identifier.
    public var description: String { rawValue }
}

/// Identifies one normalized task from a Fleet work source.
public struct FleetTaskID: Hashable, Codable, Sendable, RawRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    /// The stable source key, such as `github:owner/repo#123` or `local:<uuid>`.
    public let rawValue: String

    /// Creates a task identifier from its stable source key.
    /// - Parameter rawValue: The stable task key.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a task identifier from its stable source key.
    /// - Parameter rawValue: The stable task key.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a task identifier from a string literal.
    /// - Parameter value: The stable task key.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The display-neutral textual form of the identifier.
    public var description: String { rawValue }
}

/// Identifies one supervised attempt for a Fleet task.
public struct FleetRunID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The stable run key assigned by the engine.
    public let rawValue: String

    /// Creates a run identifier from its stable string value.
    /// - Parameter rawValue: The stable run key.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a run identifier from its stable string value.
    /// - Parameter rawValue: The stable run key.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a run identifier from a string literal.
    /// - Parameter value: The stable run key.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The display-neutral textual form of the identifier.
    public var description: String { rawValue }
}
