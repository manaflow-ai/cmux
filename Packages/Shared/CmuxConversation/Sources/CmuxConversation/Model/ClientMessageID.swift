import Foundation

/// A client-generated identifier for one outgoing message.
///
/// The GUI creates it before sending, shows the message under it at once,
/// and sends it with the message, so a resend after a dropped link never
/// runs twice and the backend's echo merges into the row already on screen.
public struct ClientMessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier's string form, sent to the backend.
    public let rawValue: String

    /// Wraps an existing identifier (for example one echoed by a backend).
    /// - Parameter rawValue: The identifier's string form.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh random identifier.
    /// - Returns: A new identifier backed by a lowercase UUID.
    public static func generate() -> ClientMessageID {
        ClientMessageID(UUID().uuidString.lowercased())
    }

    /// The raw identifier.
    public var description: String { rawValue }
}
