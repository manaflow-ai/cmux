import Foundation
import Testing

@testable import CmuxGit

@Suite("Git HEAD file content reader")
struct SystemGitHeadContentReaderTests {
    @Test("Reads the committed content of a tracked file")
    func readsCommittedContentOfTrackedFile() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("tracked.txt", "committed\n")
        try fixture.git(["add", "tracked.txt"])
        try fixture.commit("baseline")
        try fixture.write("tracked.txt", "working copy\n")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        )

        #expect(content == Data("committed\n".utf8))
    }

    @Test("Reads a tracked file that sits in a subdirectory")
    func readsTrackedFileInSubdirectory() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("nested/deep/file.txt", "nested base\n")
        try fixture.git(["add", "nested/deep/file.txt"])
        try fixture.commit("baseline")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("nested/deep/file.txt").path
        )

        #expect(content == Data("nested base\n".utf8))
    }

    @Test("Returns committed bytes unchanged for a non-UTF-8 file")
    func returnsCommittedBytesForNonUTF8File() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        try fixture.write("latin1.txt", latin1)
        try fixture.git(["add", "latin1.txt"])
        try fixture.commit("baseline")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("latin1.txt").path
        )

        #expect(content == latin1)
    }

    @Test("A symbolic link reads the committed file it points to")
    func symbolicLinkReadsTargetFile() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("target.txt", "target\n")
        try fixture.git(["add", "target.txt"])
        try fixture.commit("baseline")
        let link = fixture.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.root.appendingPathComponent("target.txt")
        )

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(forFile: link.path)

        #expect(content == Data("target\n".utf8))
    }

    @Test("Content over the size budget is not used as a base")
    func contentOverSizeBudgetIsRejected() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("large.txt", "0123456789\n")
        try fixture.git(["add", "large.txt"])
        try fixture.commit("baseline")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL),
            maximumContentByteCount: 4
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("large.txt").path
        )

        #expect(content == nil)
    }

    @Test("An untracked file has no HEAD content")
    func untrackedFileHasNoHeadContent() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()
        try fixture.write("untracked.txt", "new\n")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("untracked.txt").path
        )

        #expect(content == nil)
    }

    @Test("A file outside any repository has no HEAD content")
    func fileOutsideRepositoryHasNoHeadContent() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        try fixture.write("loose.txt", "loose\n")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("loose.txt").path
        )

        #expect(content == nil)
    }

    @Test("A relative path is rejected before reaching git")
    func relativePathIsRejected() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )

        #expect(await reader.headContent(forFile: "tracked.txt") == nil)
        #expect(await reader.watchedPaths(forFile: "tracked.txt") == nil)
    }

    @Test("Watches HEAD, the index, and the checked-out branch ref")
    func watchesHeadIndexAndBranchRef() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let paths = try #require(await reader.watchedPaths(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        ))

        // Temporary paths mix /var and /private/var, so compare repository-relative suffixes.
        #expect(paths.contains { $0.hasSuffix("/.git/HEAD") })
        #expect(paths.contains { $0.hasSuffix("/.git/index") })
        #expect(paths.contains { $0.hasSuffix("/.git/refs/heads/main") })
        #expect(paths == paths.sorted())
    }

    @Test("Only paths that exist are watched")
    func onlyExistingPathsAreWatched() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL),
            fileExists: { $0.hasSuffix("/HEAD") }
        )
        let paths = try #require(await reader.watchedPaths(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        ))

        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/.git/HEAD") == true)
    }

    @Test("A detached HEAD has no branch ref to watch")
    func detachedHeadHasNoBranchRef() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()
        try fixture.git(["checkout", "--quiet", "--detach"])

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let paths = try #require(await reader.watchedPaths(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        ))

        #expect(paths.contains { $0.hasSuffix("/.git/HEAD") })
        #expect(!paths.contains { $0.contains("/refs/heads/") })
    }

    @Test("A directory outside any repository has no watched paths")
    func directoryOutsideRepositoryHasNoWatchedPaths() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        try fixture.write("loose.txt", "loose\n")

        let reader = SystemGitHeadContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let paths = await reader.watchedPaths(
            forFile: fixture.root.appendingPathComponent("loose.txt").path
        )

        #expect(paths == nil)
    }
}
