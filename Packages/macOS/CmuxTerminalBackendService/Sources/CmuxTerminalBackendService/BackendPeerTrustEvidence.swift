public import Foundation

/// Code-signing evidence for the kernel-identified backend process.
public struct BackendPeerTrustEvidence: Equatable, Sendable {
    /// The cryptographically protected code-signing identifier.
    public let signingIdentifier: String

    /// The Developer ID team, or `nil` for an ad-hoc development signature.
    public let teamIdentifier: String?

    /// The executable path reported for the live peer process.
    public let executableURL: URL

    /// The kernel process generation carried by the audit token.
    public let processIDVersion: Int32

    /// Creates peer code-signing evidence.
    ///
    /// - Parameters:
    ///   - signingIdentifier: The signed helper identifier.
    ///   - teamIdentifier: The signing team, when present.
    ///   - executableURL: The live process executable path.
    ///   - processIDVersion: The audit token's process generation.
    public init(
        signingIdentifier: String,
        teamIdentifier: String?,
        executableURL: URL,
        processIDVersion: Int32
    ) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.executableURL = executableURL
        self.processIDVersion = processIDVersion
    }
}
