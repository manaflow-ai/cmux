@testable import CmuxNextApp
import Foundation
import Testing

/// The Markdown omnibar's git facts (plans/cmux-next/markdown-omnibar-DESIGN.md section 3): one
/// `git status --porcelain=v2 --branch --ignored=matching -- <file>` parsed into the branch, its
/// upstream, ahead/behind and the file's own state; the chip text and the GitHub blob link built
/// from them; the `~` form of a path.
@Suite struct MarkdownGitStatusTests {
    private static let header = """
    # branch.oid 0123456789abcdef0123456789abcdef01234567
    # branch.head feat-cmux-next
    # branch.upstream origin/feat-cmux-next
    # branch.ab +0 -0
    """

    @Test func aCleanTrackedFileOnAnUpToDateBranchParses() {
        let status = MarkdownGitStatus.parse(Self.header + "\n")
        #expect(status.branch == "feat-cmux-next")
        #expect(status.oid == "0123456789abcdef0123456789abcdef01234567")
        #expect(status.upstream == "origin/feat-cmux-next")
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.file == .clean)
    }

    @Test(arguments: [
        ("1 .M N... 100644 100644 100644 abc abc docs/a.md", MarkdownGitStatus.FileEntry.modified),
        ("1 M. N... 100644 100644 100644 abc abc docs/a.md", .modified),
        ("1 A. N... 000000 100644 100644 000 abc docs/a.md", .modified),
        ("2 R. N... 100644 100644 100644 abc abc R100 docs/a.md\tdocs/old.md", .modified),
        ("? docs/a.md", .untracked),
        ("! docs/a.md", .ignored),
    ])
    func theFileLineGivesTheFileState(line: String, expected: MarkdownGitStatus.FileEntry) {
        #expect(MarkdownGitStatus.parse(Self.header + "\n" + line + "\n").file == expected)
    }

    @Test func aDetachedHeadWithoutUpstreamHasNoBranch() {
        let status = MarkdownGitStatus.parse("""
        # branch.oid 89abcdef0123456789abcdef0123456789abcdef
        # branch.head (detached)

        """)
        #expect(status.branch == nil)
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
    }

    @Test func aheadAndBehindParse() {
        let status = MarkdownGitStatus.parse("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -1

        """)
        #expect(status.ahead == 3)
        #expect(status.behind == 1)
    }

    private static func location(_ state: MarkdownGitLocation.State, upstream: String? = "origin/feat-cmux-next", ahead: Int = 0,
                                 relativePath: String = "plans/cmux-next/markdown-omnibar-DESIGN.md",
                                 repository: String? = "manaflow-ai/cmux", branch: String? = "feat-cmux-next") -> MarkdownGitLocation {
        MarkdownGitLocation(root: "/Users/me/fun/cmux", relativePath: relativePath, branch: branch, oid: "0123456789abcdef",
                            upstream: upstream, ahead: ahead, githubRepository: repository, state: state)
    }

    @Test func aPushedFileLinksToItsExactBlob() throws {
        let location = Self.location(.pushed)
        let url = try #require(location.blobURL)
        #expect(url.absoluteString == "https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/plans/cmux-next/markdown-omnibar-DESIGN.md")
        #expect(location.blobIsExact)
        #expect(location.chipText == "cmux · feat-cmux-next ✓")
    }

    @Test func theBlobLinkUsesTheUpstreamBranchAndEncodesThePath() throws {
        let location = Self.location(.modified, upstream: "origin/team/notes", relativePath: "docs/my notes/ü.md", branch: "local-name")
        let url = try #require(location.blobURL)
        #expect(url.absoluteString == "https://github.com/manaflow-ai/cmux/blob/team/notes/docs/my%20notes/%C3%BC.md")
        #expect(!location.blobIsExact)
        #expect(location.chipText == "cmux · local-name ●")
    }

    @Test func unpushedUntrackedAndIgnoredFilesHaveTheirOwnChipAndLink() {
        let ahead = Self.location(.unpushed, ahead: 2)
        #expect(ahead.chipText == "cmux · feat-cmux-next ↑2")
        #expect(ahead.blobURL != nil)
        #expect(!ahead.blobIsExact)
        #expect(Self.location(.unpushed, upstream: nil).blobURL == nil)
        #expect(Self.location(.untracked).blobURL == nil)
        #expect(Self.location(.untracked).chipText == "cmux · feat-cmux-next ?")
        #expect(Self.location(.ignored).blobURL == nil)
        #expect(Self.location(.pushed, repository: nil).blobURL == nil)
    }

    @Test func aDetachedHeadShowsItsShortCommitAndHasNoLink() {
        let location = Self.location(.pushed, upstream: nil, branch: nil)
        #expect(location.chipText == "cmux · 0123456")
        #expect(location.blobURL == nil)
    }

    @Test(arguments: [
        ("/Users/me/notes.md", "/Users/me", "~/notes.md"),
        ("/Users/me", "/Users/me", "~"),
        ("/Users/meow/notes.md", "/Users/me", "/Users/meow/notes.md"),
        ("/Volumes/Work/api.md", "/Users/me", "/Volumes/Work/api.md"),
        ("/Users/me/notes.md", "/Users/me/", "~/notes.md"),
    ])
    func theTildeFormShortensOnlyTheHomeFolder(path: String, home: String, expected: String) {
        #expect(MarkdownFileLocation.tildePath(path, home: home) == expected)
    }
}
