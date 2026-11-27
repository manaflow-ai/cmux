@testable import CmuxGit

actor SequencedWorkspaceChangesContentFingerprintReader:
    WorkspaceChangesContentFingerprintReading
{
    private let fingerprints: [String?]
    private var nextIndex = 0

    init(_ fingerprints: [String?]) {
        self.fingerprints = fingerprints
    }

    func contentFingerprint(repoRoot: String, relativePath: String) -> String? {
        guard fingerprints.indices.contains(nextIndex) else {
            return fingerprints.last ?? nil
        }
        defer { nextIndex += 1 }
        return fingerprints[nextIndex]
    }

    func readCount() -> Int {
        nextIndex
    }
}
