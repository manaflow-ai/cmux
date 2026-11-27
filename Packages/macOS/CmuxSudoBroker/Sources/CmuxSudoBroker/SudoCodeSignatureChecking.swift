import Foundation

/// Authenticates the enclosing app bundle and reports a sealed resource digest.
protocol SudoCodeSignatureChecking: Sendable {
    /// Validates the whole bundle signature and returns the SHA-256 recorded in its resource seal.
    ///
    /// - Parameters:
    ///   - bundleURL: The enclosing `.app` bundle.
    ///   - requirement: The pinned requirement, or `nil` for seal integrity only (ad-hoc debug builds).
    ///   - resourcePath: The sealed path relative to `Contents/`.
    /// - Returns: The 32-byte SHA-256 digest from the validated seal.
    func sealedResourceDigest(
        bundleURL: URL,
        requirement: SudoCodeSigningRequirement?,
        resourcePath: String
    ) throws -> Data
}

/// Reports the signing identity of the running process for debug-scoped pinning.
protocol SudoRunningCodeIdentityReading: Sendable {
    func designatedRequirement() throws -> SudoCodeSigningRequirement
    func teamIdentifier() -> String?
}

enum SudoCodeSignatureError: Error, Equatable {
    case staticCode(Int32)
    case requirement(Int32)
    case invalidSignature(Int32)
    case signingInformation(Int32)
    case resourceNotSealed
    case runningCode(Int32)
    case invalidPolicy
}
