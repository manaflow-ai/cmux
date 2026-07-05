import Foundation

/// A sender or participant in a normalized inbox thread.
public struct InboxParticipant: Codable, Equatable, Sendable, Hashable {
    /// Display name shown to users when available.
    public var displayName: String
    /// Optional service-specific address or handle.
    public var address: String?

    /// Creates a participant value.
    /// - Parameters:
    ///   - displayName: Display name shown to users.
    ///   - address: Optional service-specific address or handle.
    public init(displayName: String, address: String? = nil) {
        self.displayName = displayName
        self.address = address
    }
}
