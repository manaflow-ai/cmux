import Foundation
import Testing

@testable import CmuxGit

@Suite("Git HEAD file content reader")
struct GitHeadFileContentReaderTests {
    @Test("Reads the committed content of a tracked file")
    func readsCommittedContentOfTrackedFile() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("tracked.txt", "committed\n")
        try fixture.git(["add", "tracked.txt"])
        try fixture.commit("baseline")
        try fixture.write("tracked.txt", "working copy\n")

        let reader = GitHeadFileContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        )

        #expect(content == "committed\n")
    }

    @Test("Reads a tracked file that sits in a subdirectory")
    func readsTrackedFileInSubdirectory() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.write("nested/deep/file.txt", "nested base\n")
        try fixture.git(["add", "nested/deep/file.txt"])
        try fixture.commit("baseline")

        let reader = GitHeadFileContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let content = await reader.headContent(
            forFile: fixture.root.appendingPathComponent("nested/deep/file.txt").path
        )

        #expect(content == "nested base\n")
    }

    @Test("An untracked file has no HEAD content")
    func untrackedFileHasNoHeadContent() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()
        try fixture.write("untracked.txt", "new\n")

        let reader = GitHeadFileContentReader(
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

        let reader = GitHeadFileContentReader(
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

        let reader = GitHeadFileContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )

        #expect(await reader.headContent(forFile: "tracked.txt") == nil)
        #expect(await reader.indexPath(forFile: "tracked.txt") == nil)
    }

    @Test("Resolves the index path of the owning repository")
    func resolvesIndexPathOfOwningRepository() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: true)
        try fixture.makeBaseline()

        let reader = GitHeadFileContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let indexPath = await reader.indexPath(
            forFile: fixture.root.appendingPathComponent("tracked.txt").path
        )

        // Temporary paths mix /var and /private/var, so resolve both sides first.
        let resolvedRoot = fixture.root.resolvingSymlinksInPath().path
        let resolvedIndexPath = indexPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        #expect(indexPath?.hasSuffix("/.git/index") == true)
        #expect(resolvedIndexPath?.hasPrefix(resolvedRoot) == true)
    }

    @Test("A directory outside any repository has no index path")
    func directoryOutsideRepositoryHasNoIndexPath() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        try fixture.write("loose.txt", "loose\n")

        let reader = GitHeadFileContentReader(
            runner: SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL)
        )
        let indexPath = await reader.indexPath(
            forFile: fixture.root.appendingPathComponent("loose.txt").path
        )

        #expect(indexPath == nil)
    }
}
