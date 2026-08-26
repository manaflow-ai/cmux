import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitHubWebURLTests {
    @Test func fileBuildsBlobURLWithNestedPath() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "main",
            relativePathFromWorkTreeRoot: "src/App.swift",
            resource: .file
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/blob/main/src/App.swift")
    }

    @Test func folderBuildsTreeURL() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "main",
            relativePathFromWorkTreeRoot: "src/UI",
            resource: .folder
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/tree/main/src/UI")
    }

    @Test func branchWithSlashRemainsUnescapedPathSegments() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "feat/foo",
            relativePathFromWorkTreeRoot: "README.md",
            resource: .file
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/blob/feat/foo/README.md")
    }

    @Test func branchSegmentWithHashIsPercentEncoded() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "feature#123",
            relativePathFromWorkTreeRoot: "README.md",
            resource: .file
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/blob/feature%23123/README.md")
    }

    @Test func pathSegmentWithSpaceIsPercentEncoded() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "main",
            relativePathFromWorkTreeRoot: "docs/my file.md",
            resource: .file
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/blob/main/docs/my%20file.md")
    }

    @Test func emptyRelativePathOmitsTrailingSlash() {
        let url = GitMetadataService.githubWebURL(
            slug: "owner/repo",
            branch: "main",
            relativePathFromWorkTreeRoot: "",
            resource: .folder
        )
        #expect(url?.absoluteString == "https://github.com/owner/repo/tree/main")
    }

    @Test func assemblerReturnsNilForEmptySlugOrBranch() {
        #expect(
            GitMetadataService.githubWebURL(
                slug: "",
                branch: "main",
                relativePathFromWorkTreeRoot: "a.swift",
                resource: .file
            ) == nil
        )
        #expect(
            GitMetadataService.githubWebURL(
                slug: "owner/repo",
                branch: "",
                relativePathFromWorkTreeRoot: "a.swift",
                resource: .file
            ) == nil
        )
    }

    @Test func slugOrderPrefersUpstreamBeforeOrigin() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feature/x")
        try fixture.writeConfig("""
        [remote "origin"]
        \turl = https://github.com/me/fork.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl = https://github.com/owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/upstream/*
        """)
        let nested = try fixture.writeWorkingTreeFile("nested/file.swift", contents: "ok")
        let path = fixture.root.appendingPathComponent(nested.path).path

        let url = GitMetadataService.githubWebURL(forFileSystemPath: path, resource: .file)
        #expect(url?.absoluteString == "https://github.com/owner/repo/blob/feature/x/nested/file.swift")
    }

    @Test func forFileSystemPathBuildsFolderTreeURL() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
        \turl = git@github.com:owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """)
        let folder = fixture.root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = GitMetadataService.githubWebURL(forFileSystemPath: folder.path, resource: .folder)
        #expect(url?.absoluteString == "https://github.com/owner/repo/tree/main/docs")
    }

    @Test func returnsNilWhenNoGitHubRemote() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
        \turl = git@gitlab.com:owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """)
        let entry = try fixture.writeWorkingTreeFile("a.swift", contents: "x")
        let path = fixture.root.appendingPathComponent(entry.path).path
        #expect(GitMetadataService.githubWebURL(forFileSystemPath: path, resource: .file) == nil)
    }

    @Test func returnsNilWhenNoRemotes() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("[core]\n\trepositoryformatversion = 0\n")
        let entry = try fixture.writeWorkingTreeFile("a.swift", contents: "x")
        let path = fixture.root.appendingPathComponent(entry.path).path
        #expect(GitMetadataService.githubWebURL(forFileSystemPath: path, resource: .file) == nil)
    }

    @Test func returnsNilForDetachedHead() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeDetachedHead(commit: String(repeating: "a", count: 40))
        try fixture.writeConfig("""
        [remote "origin"]
        \turl = https://github.com/owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """)
        let entry = try fixture.writeWorkingTreeFile("a.swift", contents: "x")
        let path = fixture.root.appendingPathComponent(entry.path).path
        #expect(GitMetadataService.githubWebURL(forFileSystemPath: path, resource: .file) == nil)
    }

    @Test func returnsNilWhenPathOutsideWorkTree() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
        \turl = https://github.com/owner/repo.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-outside-\(UUID().uuidString).swift")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(GitMetadataService.githubWebURL(forFileSystemPath: outside.path, resource: .file) == nil)
    }

    @Test func returnsNilWhenNotARepository() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-not-a-repo-\(UUID().uuidString)")
            .path
        #expect(GitMetadataService.githubWebURL(forFileSystemPath: path, resource: .file) == nil)
    }
}
