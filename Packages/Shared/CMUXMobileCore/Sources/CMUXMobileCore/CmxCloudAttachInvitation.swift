import Foundation

/// Legacy enrollment data, no longer minted by trusted-carrier listeners.
public struct CmxCloudAttachInvitation: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Single-use enrollment URI; never log it or pass it in process arguments.
    public let uri: String
    /// Identifier returned to the control plane for enrollment approval.
    public let invitationId: String
    /// Enrollment expiry in Unix seconds.
    public let expiresAtUnix: Double

    /// The enrollment expiry date, preserving already-expired timestamps.
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtUnix) }
    /// A diagnostic summary excluding the enrollment credential and identifier.
    public var description: String { "CmxCloudAttachInvitation(expiresAtUnix: \(expiresAtUnix))" }
    /// The same redacted summary used by debug output.
    public var debugDescription: String { description }

    /// Creates legacy enrollment metadata without granting carrier trust.
    /// - Parameters:
    ///   - uri: Single-use enrollment URI.
    ///   - invitationId: Enrollment approval identifier.
    ///   - expiresAtUnix: Expiry in Unix seconds.
    public init(uri: String, invitationId: String, expiresAtUnix: Double) {
        self.uri = uri
        self.invitationId = invitationId
        self.expiresAtUnix = expiresAtUnix
    }
}
