internal import CmuxAgentChat

/// Rejects content chunks that no longer match the stat that began their transfer.
struct WorkspaceChangesContentFingerprintPolicy: Sendable {
    func validate(expected: String?, observed: String?) throws {
        guard let expected else { return }
        guard isIdentityBearing(expected),
              let observed,
              isIdentityBearing(observed),
              observed == expected else {
            throw ChatArtifactError.macUnreachable
        }
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
