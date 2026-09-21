public import Foundation

/// Declares recovery methods for a personal or team vault.
///
/// Approved-device transfer and user-held recovery keys are always supported.
/// A team may additionally provision an organization recovery recipient. This
/// value is policy metadata; it neither grants authority nor creates recovery
/// key envelopes. Accept it only from an authenticated membership manifest.
public struct MobileRemoteVaultRecoveryPolicy: Codable, Equatable, Sendable {
    /// Personal or team boundary governed by this policy.
    public let scope: MobileRemoteVaultScope
    /// Explicit organization recovery key identity, absent until provisioned.
    ///
    /// This identifier must resolve to a verified organization-held public key
    /// in the same team's authenticated membership, never a cmux server key.
    public let organizationRecoveryKeyID: UUID?

    /// Creates policy without enabling organization recovery implicitly.
    /// - Parameters:
    ///   - scope: Owner boundary, independent of the selected UI team.
    ///   - organizationRecoveryKeyID: Additional recipient explicitly provisioned
    ///     by the organization, never inherited from account membership.
    /// - Throws: Invalid organization or personal-vault recovery scope errors.
    public init(scope: MobileRemoteVaultScope, organizationRecoveryKeyID: UUID? = nil) throws {
        try scope.validate()
        if organizationRecoveryKeyID != nil, case .personal = scope {
            throw MobileRemoteVaultRecoveryError.organizationRecoveryRequiresTeam
        }
        self.scope = scope
        self.organizationRecoveryKeyID = organizationRecoveryKeyID
    }

    private enum CodingKeys: String, CodingKey { case scope, organizationRecoveryKeyID }

    /// Decodes while enforcing the same scope rules as explicit construction.
    /// - Parameter decoder: Decoder of authenticated policy metadata.
    /// - Throws: Decoding or recovery-scope errors.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: values.decode(MobileRemoteVaultScope.self, forKey: .scope),
            organizationRecoveryKeyID: values.decodeIfPresent(UUID.self, forKey: .organizationRecoveryKeyID)
        )
    }
}
