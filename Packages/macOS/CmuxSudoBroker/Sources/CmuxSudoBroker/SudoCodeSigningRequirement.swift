public import Foundation

/// A code-signing requirement that the enclosing app bundle or a staged helper must satisfy.
public struct SudoCodeSigningRequirement: Sendable, Equatable {
    /// The requirement in Apple's code-requirement language.
    public let text: String

    /// Creates a requirement from code-requirement source text.
    public init(text: String) {
        self.text = text
    }

    /// Code signed with a Developer ID Application certificate issued to one team.
    ///
    /// - Parameter teamIdentifier: The ten-character Apple team identifier.
    /// - Returns: `nil` when the identifier is malformed.
    public static func developerID(teamIdentifier: String) -> SudoCodeSigningRequirement? {
        guard isValidTeamIdentifier(teamIdentifier) else { return nil }
        return SudoCodeSigningRequirement(
            text: "anchor apple generic"
                + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
                + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        )
    }

    /// Code signed by any Apple-issued certificate belonging to one team.
    static func appleTeam(teamIdentifier: String) -> SudoCodeSigningRequirement? {
        guard isValidTeamIdentifier(teamIdentifier) else { return nil }
        return SudoCodeSigningRequirement(
            text: "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        )
    }

    static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }
}
