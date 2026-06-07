import Foundation
import Testing
@testable import CmuxGit

/// Migrated from the app target's `TabManagerPullRequestProbeTests` when the
/// git/PR subsystem moved into `CmuxGit`. Exercises remote-slug derivation
/// straight from `config`, including the `include`/`includeIf` rules.
@Suite struct GitConfigIncludeTests {
    private func slugs(fromConfig config: String) -> [String] {
        GitMetadataService.githubRepositorySlugs(
            fromGitRemoteVOutput: GitMetadataService.gitRemoteVLines(fromConfig: config).joined()
        )
    }

    private func slugs(forDirectory directory: String) -> [String] {
        guard let repository = GitMetadataService.resolveGitRepository(containing: directory),
              let output = GitMetadataService.gitRemoteVOutput(repository: repository) else {
            return []
        }
        return GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    @Test func prioritizesUpstreamThenOriginAndDeduplicates() {
        let output = """
        origin https://github.com/austinwang/cmux.git (fetch)
        origin https://github.com/austinwang/cmux.git (push)
        upstream git@github.com:manaflow-ai/cmux.git (fetch)
        upstream git@github.com:manaflow-ai/cmux.git (push)
        backup ssh://git@github.com/manaflow-ai/cmux.git (fetch)
        mirror https://gitlab.com/manaflow-ai/cmux.git (fetch)
        """
        #expect(
            GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output)
                == ["manaflow-ai/cmux", "austinwang/cmux"]
        )
    }

    @Test func ignoresInlineComments() {
        let config = """
        [remote "origin"] ; user's main fork
            url = git@github.com:austinwang/cmux.git # main origin
            fetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"] # canonical repo
            url = https://github.com/manaflow-ai/cmux.git ; upstream source
            fetch = +refs/heads/*:refs/remotes/upstream/*
        """
        #expect(slugs(fromConfig: config) == ["manaflow-ai/cmux", "austinwang/cmux"])
    }

    @Test func unquotesUrlValues() {
        let config = """
        [remote "origin"] ; user's main fork
            url = "git@github.com:austinwang/cmux.git" # main origin
            fetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"] # canonical repo
            url = "https://github.com/manaflow-ai/cmux.git" ; upstream source
            fetch = +refs/heads/*:refs/remotes/upstream/*
        """
        #expect(slugs(fromConfig: config) == ["manaflow-ai/cmux", "austinwang/cmux"])
    }

    @Test func usesLastRemoteURLValue() {
        let config = """
        [remote "origin"]
            url = https://github.com/old-owner/old-repo.git
            url = https://github.com/manaflow-ai/cmux.git
        """
        #expect(slugs(fromConfig: config) == ["manaflow-ai/cmux"])
    }

    @Test func readsIncludedConfigFiles() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = remotes.inc
        [includeIf "gitdir:\(fixture.gitDirectory.path)/**"]
            path = conditional-remotes.inc
        """)
        try """
        [remote "origin"]
            url = "git@github.com:austinwang/cmux.git" # user's main fork
        """.write(to: fixture.gitDirectory.appendingPathComponent("remotes.inc"), atomically: true, encoding: .utf8)
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git ; canonical repo
        """.write(to: fixture.gitDirectory.appendingPathComponent("conditional-remotes.inc"), atomically: true, encoding: .utf8)

        #expect(slugs(forDirectory: fixture.root.path) == ["manaflow-ai/cmux", "austinwang/cmux"])
    }

    @Test func appliesIncludesInPlace() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = remotes.inc
        [remote "origin"]
            url = https://github.com/manaflow-ai/cmux.git
        """)
        try """
        [remote "origin"]
            url = https://github.com/old-owner/old-repo.git
        """.write(to: fixture.gitDirectory.appendingPathComponent("remotes.inc"), atomically: true, encoding: .utf8)

        // The in-place include is read first, so the later top-level url wins.
        #expect(slugs(forDirectory: fixture.root.path) == ["manaflow-ai/cmux"])
    }

    @Test func treatsTrailingSlashGitdirAsRecursive() throws {
        // Repo nested under a parent; an includeIf gitdir with a trailing slash
        // must match recursively.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-recursive-\(UUID().uuidString)", isDirectory: true)
        let repoRoot = parent.appendingPathComponent("teams/cmux", isDirectory: true)
        let gitDir = repoRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try """
        [includeIf "gitdir:\(parent.path)/"]
            path = recursive-remotes.inc
        """.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(to: gitDir.appendingPathComponent("recursive-remotes.inc"), atomically: true, encoding: .utf8)

        #expect(slugs(forDirectory: repoRoot.path) == ["manaflow-ai/cmux"])
    }

    // MARK: Submodule watched paths (migrated from the sidebar integration test)

    @Test func watchedPathsIncludeSubmoduleHeadAndRefs() throws {
        let parent = try GitRepositoryFixture()
        try parent.writeBranch("main")
        let indexedCommit = String(repeating: "1", count: 40)

        // Create a real submodule checkout under vendor/lib with its own HEAD.
        let submoduleRoot = parent.root.appendingPathComponent("vendor/lib", isDirectory: true)
        let submoduleGit = submoduleRoot.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: submoduleGit.appendingPathComponent("refs/heads"),
            withIntermediateDirectories: true
        )
        try "\(indexedCommit)\n".write(to: submoduleGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Parent index records the gitlink (mode 0o160000) at vendor/lib.
        let gitlink = GitIndexFixture.Entry(path: "vendor/lib", mode: 0o160000, objectID: indexedCommit, size: 0)
        try parent.writeIndex(GitIndexFixture(version: 2, entries: [gitlink]))

        let paths = try #require(GitMetadataService.workspaceGitMetadataWatchedPaths(for: parent.root.path))
        #expect(paths.contains(submoduleGit.appendingPathComponent("HEAD").standardizedFileURL.path))
        #expect(paths.contains(submoduleGit.appendingPathComponent("refs").standardizedFileURL.path))
    }
}
