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
        #expect(GitMetadataService.githubRepositorySlug(fromRemoteURL: url) == "manaflow-ai/cmux")
    }

    @Test func ignoresNonGitHubRemotes() {
        #expect(GitMetadataService.githubRepositorySlug(fromRemoteURL: "git@gitlab.com:foo/bar.git") == nil)
        #expect(GitMetadataService.githubRepositorySlug(fromRemoteURL: "") == nil)
    }

    @Test func ordersRemotesUpstreamThenOriginThenRest() {
        let output = """
        origin\thttps://github.com/me/fork.git (fetch)
        upstream\thttps://github.com/owner/repo.git (fetch)
        zeta\thttps://github.com/zeta/zeta.git (fetch)
        """
        #expect(
            GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output)
                == ["owner/repo", "me/fork", "zeta/zeta"]
        )
    }

    @Test func deduplicatesIdenticalSlugs() {
        let output = """
        origin\thttps://github.com/owner/repo.git (fetch)
        mirror\tgit@github.com:owner/repo.git (fetch)
        """
        #expect(GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output) == ["owner/repo"])
    }

    @Test func ignoresPushOnlyLines() {
        let output = "origin\thttps://github.com/owner/repo.git (push)\n"
        #expect(GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output).isEmpty)
    }

    // MARK: config parsing

    @Test func remoteVLinesParseUrlFromConfig() {
        let config = """
        [remote "origin"]
        \turl = https://github.com/owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        let slugs = GitMetadataService.githubRepositorySlugs(
            fromGitRemoteVOutput: GitMetadataService.gitRemoteVLines(fromConfig: config).joined()
        )
        #expect(slugs == ["owner/repo"])
    }

    @Test func inlineCommentsAreStrippedOutsideQuotes() {
        let line = GitMetadataService.gitConfigLineRemovingInlineComment("\turl = value # trailing comment")
        #expect(line.trimmingCharacters(in: .whitespaces) == "url = value")
    }

    @Test func inlineCommentInsideQuotesIsKept() {
        let line = GitMetadataService.gitConfigLineRemovingInlineComment("\turl = \"a#b\"")
        #expect(line.contains("a#b"))
    }

    @Test func globMatchesSingleSegmentWildcard() {
        #expect(GitMetadataService.gitConfigGlobMatches("/a/b", pattern: "/a/*", caseInsensitive: false))
        #expect(!GitMetadataService.gitConfigGlobMatches("/a/b/c", pattern: "/a/*", caseInsensitive: false))
    }

    @Test func globDoubleStarMatchesAcrossSegments() {
        #expect(GitMetadataService.gitConfigGlobMatches("/a/b/c/d", pattern: "/a/**/d", caseInsensitive: false))
    }

    @Test func includeIfGitdirRecursiveMatchesNestedRepository() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let condition = "gitdir:\(fixture.gitDirectory.path)/"
        #expect(GitMetadataService.gitConfigIncludeIfConditionMatches(
            condition,
            repository: try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        ))
    }
}
