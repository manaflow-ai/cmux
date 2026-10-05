import Foundation

/// A user-selected workspace marker independent of agent activity and pinning.
public enum CmuxSidebarWorkspaceImportance: String, Codable, CaseIterable, Equatable, Sendable {
    /// No importance marker.
    case none
    /// The workspace is a priority.
    case priority
    /// The workspace requires later follow-up.
    case followUp

    /// Decodes a marker, treating a future unknown value as unmarked.
    ///
    /// - Parameter decoder: Decoder containing a raw importance value.
    /// - Throws: A decoding error if the value is not a string.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .none
    }
}
