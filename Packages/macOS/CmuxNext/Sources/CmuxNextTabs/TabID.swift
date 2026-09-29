import Foundation

/// Stable identity of one tab. The App layer uses the daemon's tab id.
public struct TabID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}
