internal import Foundation

/// Pure compatibility policy for current-line expansion revision checks.
public struct DiffExpansionRevisionPolicy: Sendable {
    /// Creates the standard expansion revision policy.
    public init() {}

    /// Compares a diff revision with fingerprints observed while fetching current lines.
    ///
    /// Missing fingerprints preserve compatibility with older hosts. When the
    /// diff has a fingerprint, every fingerprint supplied by a newer host must
    /// match it.
    ///
    /// - Parameters:
    ///   - diffContentFingerprint: Fingerprint attached to the loaded diff.
    ///   - fetchedContentFingerprints: Fingerprints from stat and chunk responses.
    /// - Returns: Whether to use the fetched lines or reload the diff.
    public func decision(
        diffContentFingerprint: String?,
        fetchedContentFingerprints: [String]
    ) -> DiffExpansionRevisionDecision {
        guard let expected = diffContentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            return .accept
        }
        let observed = fetchedContentFingerprints.filter { !$0.isEmpty }
        guard !observed.isEmpty else { return .accept }
        return observed.allSatisfy { $0 == expected } ? .accept : .reloadDiff
    }
}
