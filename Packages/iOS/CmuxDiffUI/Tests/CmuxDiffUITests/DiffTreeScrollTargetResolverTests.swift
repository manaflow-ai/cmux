import CmuxMobileRPC
import Testing
@testable import CmuxDiffUI

@Suite struct DiffTreeScrollTargetResolverTests {
    @Test func resolvesCurrentFileAndRejectsStaleOrDirectoryPaths() {
        let files = [
            DiffFileSnapshot(
                summary: MobileDiffFileSummary(
                    path: "Sources/App.swift",
                    status: .modified,
                    additions: 1,
                    deletions: 0,
                    isBinary: false,
                    isLarge: false,
                    patchDigest: "digest"
                ),
                content: .loading
            ),
        ]
        let resolver = DiffTreeScrollTargetResolver()

        #expect(resolver.target(path: "Sources/App.swift", files: files) == "diff-file:Sources/App.swift")
        #expect(resolver.target(path: "Sources", files: files) == nil)
        #expect(resolver.target(path: "Deleted.swift", files: files) == nil)
    }
}
