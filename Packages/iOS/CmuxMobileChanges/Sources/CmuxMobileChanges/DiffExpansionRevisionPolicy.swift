internal import Foundation

/// Pure compatibility policy for current-line expansion revision checks.
public struct DiffExpansionRevisionPolicy: Sendable {
    /// Creates the standard expansion revision policy.
    public init() {}

    /// Compares a diff revision with fingerprints observed while fetching current lines.
    ///
    /// An all-missing legacy workflow remains compatible. Once the diff has a
    /// fingerprint, every stat and content response must carry the same token.
    ///
    /// - Parameters:
    ///   - diffContentFingerprint: Fingerprint attached to the loaded diff.
    ///   - fetchedContentFingerprints: Fingerprints from stat and chunk responses.
    /// - Returns: Whether to use the fetched lines or reload the diff.
    public func decision(
        diffContentFingerprint: String?,
        fetchedContentFingerprints: [String?]
    ) -> DiffExpansionRevisionDecision {
        guard let expected = diffContentFingerprint else {
            return .accept
        }
        guard !fetchedContentFingerprints.isEmpty,
              fetchedContentFingerprints.allSatisfy({ $0 == expected }) else {
            return .reloadDiff
        }
        return .accept
    }
}
