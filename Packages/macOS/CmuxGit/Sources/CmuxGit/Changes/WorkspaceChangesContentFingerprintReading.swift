/// Reads the working-tree fingerprint used to pin a diff response.
protocol WorkspaceChangesContentFingerprintReading: Sendable {
    func contentFingerprint(repoRoot: String, relativePath: String) async -> String?
}
