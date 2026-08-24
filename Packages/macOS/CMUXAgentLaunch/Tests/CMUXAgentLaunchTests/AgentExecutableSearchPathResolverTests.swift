import Testing
@testable import CMUXAgentLaunch

@Suite("Agent executable search path resolver")
struct AgentExecutableSearchPathResolverTests {
    @Test("Checks raw relative paths before normalizing parent traversal")
    func checksRawRelativePathsBeforeNormalization() {
        let root = "/tmp/cmux-search-path-root"
        let existing = Set([
            "\(root)/.",
            "\(root)/./bin",
            "\(root)/bin",
        ])
        let resolver = AgentExecutableSearchPathResolver(
            currentDirectoryPath: root,
            directoryExists: { existing.contains($0) }
        )

        #expect(
            resolver.normalizedDirectories(from: [
                "missing-directory/..",
                ".",
                "./bin",
                "bin",
            ]) == [root, "\(root)/bin"]
        )
    }

    @Test("Rejects control and replacement scalars before trimming")
    func rejectsMalformedScalarsBeforeTrimming() {
        let root = "/tmp/cmux-search-path-root"
        let resolver = AgentExecutableSearchPathResolver(
            currentDirectoryPath: root,
            directoryExists: { _ in true }
        )

        #expect(
            resolver.normalizedDirectories(from: [
                "\n.",
                ".\n",
                "bad\u{FFFD}",
                "bin",
            ]) == ["\(root)/bin"]
        )
    }
}
