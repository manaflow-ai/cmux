internal import CmuxAgentChat

/// Rejects content chunks that no longer match the stat that began their transfer.
struct WorkspaceChangesContentFingerprintPolicy: Sendable {
    func validate(expected: String?, observed: String?) throws {
        guard let expected else { return }
        guard observed == expected else {
            throw ChatArtifactError.macUnreachable
        }
    }
}
