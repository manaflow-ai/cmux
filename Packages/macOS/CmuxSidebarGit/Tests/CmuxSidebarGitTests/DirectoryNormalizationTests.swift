import Testing
@testable import CmuxSidebarGit

@Suite struct DirectoryNormalizationTests {
    @Test func trimsWhitespace() {
        #expect("  /tmp/x  ".normalizedGitProbeDirectory == "/tmp/x")
    }

    @Test func emptyStaysOriginal() {
        #expect("   ".normalizedGitProbeDirectory == "   ")
    }

    @Test func fileURLBecomesPath() {
        #expect("file:///tmp/x".normalizedGitProbeDirectory == "/tmp/x")
    }

    @Test func nonEmptyVariantNilsOutBlank() {
        #expect("   ".nonEmptyNormalizedGitProbeDirectory == nil)
        #expect("/tmp/x".nonEmptyNormalizedGitProbeDirectory == "/tmp/x")
    }
}
