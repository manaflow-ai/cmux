internal import CmuxAgentChat

/// Rejects content chunks that no longer match the stat that began their transfer.
struct WorkspaceChangesContentFingerprintPolicy: Sendable {
    func validate(expected: String?, observed: String?) throws {
        guard let expected,
              let observed,
              isIdentityBearing(expected),
              isIdentityBearing(observed),
              observed == expected else {
            throw ChatArtifactError.macUnreachable
        }
    }

    private func isIdentityBearing(_ fingerprint: String) -> Bool {
        let components = fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        if components.count == 3, components[0] == "blob" {
            return !components[1].isEmpty && !components[2].isEmpty
        }
        return components.count == 6
            && components[0] == "stat"
            && Int64(components[1]).map { $0 >= 0 } == true
            && Int64(components[2]) != nil
            && UInt64(components[3]) != nil
            && UInt64(components[4]) != nil
            && Int64(components[5]) != nil
    }
}
