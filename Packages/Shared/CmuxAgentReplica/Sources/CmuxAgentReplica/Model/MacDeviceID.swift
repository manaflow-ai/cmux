import Foundation

/// Identifies the Mac that owns replicated agent state.
public struct MacDeviceID: Codable, Hashable, Sendable, RawRepresentable {
    /// The opaque Mac device identifier.
    public let rawValue: String

    /// Creates a Mac device identifier.
    /// - Parameter rawValue: The opaque identifier value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
