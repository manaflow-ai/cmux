public import Foundation

/// A stable identifier for one managed conversation session.
public struct ConversationID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Creates an identifier from a non-empty string.
    /// - Parameter rawValue: The stable identifier string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a string literal.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A stable identifier for one rendered conversation item.
public struct ConversationItemID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    /// Creates an item identifier.
    /// - Parameter rawValue: The stable identifier string.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates an item identifier from a string literal.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A stable identifier for one provider turn.
public struct ConversationTurnID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    /// Creates a turn identifier.
    /// - Parameter rawValue: The stable identifier string.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates a turn identifier from a string literal.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A stable identifier for an approval or question request.
public struct ConversationRequestID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    /// Creates a request identifier.
    /// - Parameter rawValue: The stable identifier string.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates a request identifier from a string literal.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A stable identifier for a durable command attempt.
public struct ConversationCommandID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    /// Creates a command identifier.
    /// - Parameter rawValue: The stable identifier string.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates a command identifier from a string literal.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A monotonic cursor into a conversation's event journal.
public typealias ConversationCursor = UInt64

/// A provider generation that invalidates stale requests after a restart.
public typealias ConversationGeneration = String
