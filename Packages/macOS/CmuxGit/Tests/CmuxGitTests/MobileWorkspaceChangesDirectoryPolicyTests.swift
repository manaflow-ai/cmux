import Testing
@testable import CmuxGit

@Suite struct MobileWorkspaceChangesDirectoryPolicyTests {
    private let policy = MobileWorkspaceChangesDirectoryPolicy()

    @Test func remoteProvenanceNeverResolvesPresentedPathAsLocal() {
        let resolution = policy.resolve(
            presentedDirectory: "/srv/checkout",
            usesRemoteDirectoryProvenance: true
        )

        #expect(resolution == .remote)
    }

    @Test func localAndUnavailableDirectoriesRemainDistinct() {
        #expect(policy.resolve(
            presentedDirectory: "/Users/test/checkout",
            usesRemoteDirectoryProvenance: false
        ) == .local("/Users/test/checkout"))
        #expect(policy.resolve(
            presentedDirectory: nil,
            usesRemoteDirectoryProvenance: false
        ) == .unavailable)
    }
}
