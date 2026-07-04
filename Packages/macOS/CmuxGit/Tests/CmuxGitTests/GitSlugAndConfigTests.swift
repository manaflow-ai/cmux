import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitSlugAndConfigTests {
    @Test(arguments: [
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux.git",
        "http://github.com/manaflow-ai/cmux",
        "git://github.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
    ])
    func parsesGitHubRemoteForms(url: String) {
        #expect(GitMetadataService().githubRepositorySlug(fromRemoteURL: url) == "manaflow-ai/cmux")
    }

    @Test func ignoresNonGitHubRemotes() {
        #expect(GitMetadataService().githubRepositorySlug(fromRemoteURL: "git@gitlab.com:foo/bar.git") == nil)
        #expect(GitMetadataService().githubRepositorySlug(fromRemoteURL: "") == nil)
    }

    @Test func ordersRemotesUpstreamThenOriginThenRest() {
        let output = """
        origin\thttps://github.com/me/fork.git (fetch)
        upstream\thttps://github.com/owner/repo.git (fetch)
        zeta\thttps://github.com/zeta/zeta.git (fetch)
        """
        #expect(
            GitMetadataService().githubRepositorySlugs(fromGitRemoteVOutput: output)
                == ["owner/repo", "me/fork", "zeta/zeta"]
        )
    }

    @Test func deduplicatesIdenticalSlugs() {
        let output = """
        origin\thttps://github.com/owner/repo.git (fetch)
        mirror\tgit@github.com:owner/repo.git (fetch)
        """
        #expect(GitMetadataService().githubRepositorySlugs(fromGitRemoteVOutput: output) == ["owner/repo"])
    }

    @Test func ignoresPushOnlyLines() {
        let output = "origin\thttps://github.com/owner/repo.git (push)\n"
        #expect(GitMetadataService().githubRepositorySlugs(fromGitRemoteVOutput: output).isEmpty)
    }

    // MARK: config parsing

    @Test func remoteVLinesParseUrlFromConfig() {
        let config = """
        [remote "origin"]
        \turl = https://github.com/owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        let slugs = GitMetadataService().githubRepositorySlugs(
            fromGitRemoteVOutput: GitMetadataService().gitRemoteVLines(fromConfig: config).joined()
        )
        #expect(slugs == ["owner/repo"])
    }

    @Test func inlineCommentsAreStrippedOutsideQuotes() {
        let line = GitMetadataService().gitConfigLineRemovingInlineComment("\turl = value # trailing comment")
        #expect(line.trimmingCharacters(in: .whitespaces) == "url = value")
    }

    @Test func inlineCommentInsideQuotesIsKept() {
        let line = GitMetadataService().gitConfigLineRemovingInlineComment("\turl = \"a#b\"")
        #expect(line.contains("a#b"))
    }

    @Test func globMatchesSingleSegmentWildcard() {
        #expect(GitMetadataService().gitConfigGlobMatches("/a/b", pattern: "/a/*", caseInsensitive: false))
        #expect(!GitMetadataService().gitConfigGlobMatches("/a/b/c", pattern: "/a/*", caseInsensitive: false))
    }

    @Test func globDoubleStarMatchesAcrossSegments() {
        #expect(GitMetadataService().gitConfigGlobMatches("/a/b/c/d", pattern: "/a/**/d", caseInsensitive: false))
    }

    @Test func includeIfGitdirRecursiveMatchesNestedRepository() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let condition = "gitdir:\(fixture.gitDirectory.path)/"
        #expect(GitMetadataService().gitConfigIncludeIfConditionMatches(
            condition,
            repository: try #require(GitMetadataService().resolveGitRepository(containing: fixture.root.path)),
            configURL: fixture.gitDirectory.appendingPathComponent("config")
        ))
    }

    // MARK: Parsing fidelity (issue #5359)

    private func slugs(fromConfig config: String) -> [String] {
        GitMetadataService().githubRepositorySlugs(
            fromGitRemoteVOutput: GitMetadataService().gitRemoteVLines(fromConfig: config).joined()
        )
    }

    private func slugs(forDirectory directory: String) -> [String] {
        guard let repository = GitMetadataService().resolveGitRepository(containing: directory),
              let output = GitMetadataService().gitRemoteVOutput(repository: repository) else {
            return []
        }
        return GitMetadataService().githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    @Test func configSectionAndKeyNamesAreCaseInsensitive() {
        let config = """
        [Remote "origin"]
            URL = https://github.com/manaflow-ai/cmux.git
        """
        #expect(slugs(fromConfig: config) == ["manaflow-ai/cmux"])
    }

    @Test func includeHeaderIsCaseInsensitiveAndSubsectionCasePreserved() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [INCLUDE]
            path = remotes.inc
        """)
        try """
        [remote "MixedCase"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(to: fixture.gitDirectory.appendingPathComponent("remotes.inc"), atomically: true, encoding: .utf8)
        #expect(slugs(forDirectory: fixture.root.path) == ["manaflow-ai/cmux"])
    }

    @Test func relativeGitdirPatternMatchesAtAnyDepth() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(GitMetadataService().resolveGitRepository(containing: fixture.root.path))
        let configURL = fixture.gitDirectory.appendingPathComponent("config")
        // Relative pattern (no leading /, ~/, ./) gets **/ prepended per git,
        // so "<rootDirName>/.git/" matches the absolute git directory.
        let rootDirName = fixture.root.lastPathComponent
        #expect(GitMetadataService().gitConfigIncludeIfConditionMatches(
            "gitdir:\(rootDirName)/.git/",
            repository: repository,
            configURL: configURL
        ))
        #expect(!GitMetadataService().gitConfigIncludeIfConditionMatches(
            "gitdir:not-the-dir/.git/",
            repository: repository,
            configURL: configURL
        ))
    }

    @Test func dotSlashGitdirPatternIsRelativeToConfigDirectory() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(GitMetadataService().resolveGitRepository(containing: fixture.root.path))
        // "./" in the .git/config means the .git directory itself; with the
        // trailing-slash recursion rule it matches the git directory.
        #expect(GitMetadataService().gitConfigIncludeIfConditionMatches(
            "gitdir:./",
            repository: repository,
            configURL: fixture.gitDirectory.appendingPathComponent("config")
        ))
        // Anchored to a different config directory, the same pattern must not match.
        #expect(!GitMetadataService().gitConfigIncludeIfConditionMatches(
            "gitdir:./",
            repository: repository,
            configURL: URL(fileURLWithPath: "/somewhere/else/config")
        ))
    }
}
