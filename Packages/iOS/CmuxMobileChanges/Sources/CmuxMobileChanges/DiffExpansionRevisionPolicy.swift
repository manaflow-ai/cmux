internal import Foundation

/// Pure policy for current-line expansion revision checks.
public struct DiffExpansionRevisionPolicy: Sendable {
    /// Creates the standard expansion revision policy.
    public init() {}

    /// Compares a diff revision with fingerprints observed while fetching current lines.
    ///
    /// The workspace-changes capability always carries fingerprints, so every
    /// diff, stat, and content response must carry the same identity token.
    ///
    /// - Parameters:
    ///   - diffContentFingerprint: Fingerprint attached to the loaded diff.
    ///   - fetchedContentFingerprints: Fingerprints from stat and chunk responses.
    /// - Returns: Whether to use the fetched lines or reload the diff.
    public func decision(
        diffContentFingerprint: String?,
        fetchedContentFingerprints: [String?]
    ) -> DiffExpansionRevisionDecision {
        guard let expected = diffContentFingerprint,
              isIdentityBearing(expected),
              !fetchedContentFingerprints.isEmpty,
              fetchedContentFingerprints.allSatisfy({
                  guard let observed = $0 else { return false }
                  return isIdentityBearing(observed) && observed == expected
              }) else {
            return .reloadDiff
        }
        return .accept
    }

    private func isIdentityBearing(_ fingerprint: String) -> Bool {
        let components = fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6,
              components[0] == "stat",
              let size = Int64(components[1]),
              size >= 0,
              Int64(components[2]) != nil,
              UInt64(components[3]) != nil,
              UInt64(components[4]) != nil,
              Int64(components[5]) != nil else {
            return false
        }
        return true
    }
}
