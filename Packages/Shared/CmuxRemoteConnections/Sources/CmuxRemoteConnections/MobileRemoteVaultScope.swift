import Foundation

/// The personal or organization boundary that governs one vault.
public enum MobileRemoteVaultScope: Codable, Equatable, Sendable {
    /// A personal vault whose keys are never placed in organization recovery.
    case personal
    /// A team vault governed by the specified organization.
    case team(organizationID: String)

    private enum CodingKeys: String, CodingKey { case kind, organizationID }
    private enum Kind: String, Codable { case personal, team }

    /// Decodes a scope while validating its organization binding.
    /// - Parameter decoder: Decoder of authenticated vault metadata.
    /// - Throws: Decoding or invalid-organization errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .personal:
            guard !values.contains(.organizationID) else {
                throw MobileRemoteVaultRecoveryError.invalidOrganization
            }
            self = .personal
        case .team:
            self = .team(organizationID: try values.decode(String.self, forKey: .organizationID))
        }
        try validate()
    }

    /// Checks a scope before it is used or encoded.
    /// - Throws: An error for empty, oversized, or control-character organization IDs.
    public func validate() throws {
        if case let .team(organizationID) = self {
            guard !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  organizationID.utf8.count <= 256,
                  !organizationID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MobileRemoteVaultRecoveryError.invalidOrganization
            }
        }
    }

    /// Encodes a validated scope with an explicit personal/team discriminator.
    /// - Parameter encoder: Destination for vault metadata.
    /// - Throws: Encoding or invalid-organization errors.
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .personal:
            try values.encode(Kind.personal, forKey: .kind)
        case let .team(organizationID):
            try values.encode(Kind.team, forKey: .kind)
            try values.encode(organizationID, forKey: .organizationID)
        }
    }
}
