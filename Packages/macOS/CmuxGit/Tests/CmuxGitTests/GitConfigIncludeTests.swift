import Darwin
import Foundation
import Testing
@testable import CmuxGit

private nonisolated struct FixedGitReferenceReader: GitReferenceReading {
    let branchName: String?

    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        GitReferenceSnapshot(
            checkedOutBranch: branchName.map { GitCheckedOutBranch.branch($0) } ?? .detached,
            headSignature: branchName,
            currentCommit: nil
        )
    }
}

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

    @Test func onBranchIncludesUseResolvedReferenceContext() throws {
        let fixture = try GitRepositoryFixture()
        try "ref: refs/heads/.invalid\n".write(
            to: fixture.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeConfig("""
        [includeIf "onbranch:feature/**"]
            path = branch-remotes.inc
        """)
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("branch-remotes.inc"),
            atomically: true,
            encoding: .utf8
        )

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let output = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved("feature/reftable-sidebar")
        ).remoteVOutput()

        #expect(
            GitMetadataService.githubRepositorySlugs(fromGitRemoteVOutput: output ?? "")
                == ["manaflow-ai/cmux"]
        )
    }

    @Test func metadataServiceThreadsResolvedBranchIntoConfigTraversal() async throws {
        let fixture = try GitRepositoryFixture()
        try "ref: refs/heads/.invalid\n".write(
            to: fixture.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeConfig("""
        [includeIf "onbranch:feature/**"]
            path = branch-remotes.inc
        """)
        let includedURL = fixture.gitDirectory.appendingPathComponent("branch-remotes.inc")
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(to: includedURL, atomically: true, encoding: .utf8)

        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            referenceReader: FixedGitReferenceReader(branchName: "feature/reftable-sidebar")
        )
        #expect(await service.repositorySlugs(forDirectory: fixture.root.path) == ["manaflow-ai/cmux"])

        let descriptor = try #require(await service.watchDescriptor(for: fixture.root.path))
        #expect(descriptor.watchedPaths.contains(includedURL.standardizedFileURL.path))
    }

    @Test func branchAwareTraversalSkipsNonRegularIncludedFiles() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feature/reftable-sidebar")
        try fixture.writeConfig("""
        [includeIf "onbranch:feature/**"]
            path = blocked.inc
        """)
        let fifoURL = fixture.gitDirectory.appendingPathComponent("blocked.inc")
        let fifoResult = fifoURL.path.withCString { path in
            mkfifo(path, mode_t(0o600))
        }
        #expect(fifoResult == 0)
        defer {
            fifoURL.path.withCString { path in
                _ = Darwin.unlink(path)
            }
        }

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let output = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved("feature/reftable-sidebar")
        ).remoteVOutput()

        #expect(output == nil)
    }

    @Test func missingRepositoryIncludeUsesExactCreationSentinel() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = optional-remotes.inc
        """)
        let missingURL = fixture.gitDirectory.appendingPathComponent("optional-remotes.inc")
        let service = GitMetadataService()
        let descriptor = try #require(await service.watchDescriptor(for: fixture.root.path))

        #expect(descriptor.watchedPaths.contains(fixture.gitDirectory.standardizedFileURL.path))
        #expect(!descriptor.gitMetadataPaths.contains(fixture.gitDirectory.standardizedFileURL.path))
        #expect(descriptor.containsGitMetadataChange(paths: [missingURL.path]))
        #expect(!descriptor.containsGitMetadataChange(
            paths: [fixture.gitDirectory.appendingPathComponent("info/other").path]
        ))
        #expect(descriptor.containsRelevantChange(paths: [missingURL.path]))
    }

    @Test func missingExternalReferenceMarkerDoesNotWatchExternalRoot() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let externalRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("cmuxgit-empty-ref-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        try fixture.writeConfig("""
        [extensions]
            refStorage = reftable:\(externalRoot.path)
        """)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let result = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved("main"),
            includeConditionalPathsForWatch: true
        ).watchPathResult()

        #expect(!result.paths.contains(externalRoot.path))
        #expect(!result.paths.contains(externalRoot.appendingPathComponent("tables.list").path))
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

    @Test func includeTraversalStopsAtItsPathBudget() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let includes = (0..<400)
            .map { "    path = missing-\($0).inc" }
            .joined(separator: "\n")
        try fixture.writeConfig("[include]\n\(includes)\n")

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let result = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved("main"),
            includeConditionalPathsForWatch: true
        ).watchPathResult()

        #expect(result.metadataSentinelPaths.count == 255)
        #expect(!result.metadataSentinelPaths.contains { $0.hasSuffix("missing-399.inc") })
        #expect(result.paths.contains(fixture.gitDirectory.standardizedFileURL.path))
    }

    @Test func deferredIncludeOutsideGitDirectoryStillInvalidatesMetadata() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let deferredInclude = fixture.root.appendingPathComponent("remotes.inc")
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(to: deferredInclude, atomically: true, encoding: .utf8)
        let missingIncludes = (0..<255)
            .map { "    path = missing-\($0).inc" }
            .joined(separator: "\n")
        try """
        [include]
        (missingIncludes)
            path = ../remotes.inc
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )

        #expect(descriptor.metadataSentinelPaths.contains(deferredInclude.path))
        #expect(descriptor.containsGitMetadataChange(paths: [deferredInclude.path]))
    }

    @Test func watchesGitDirectoryUntilMissingWorktreeConfigAppears() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = true
        """)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let paths = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved("main")
        ).watchPaths()

        #expect(paths.contains(fixture.gitDirectory.standardizedFileURL.path))
    }

    @Test func missingWorktreeConfigUsesExactCreationSentinel() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = true
        """)
        let configWorktreeURL = fixture.gitDirectory.appendingPathComponent("config.worktree")
        let descriptor = try #require(
            await GitMetadataService().watchDescriptor(for: fixture.root.path)
        )

        #expect(descriptor.metadataSentinelPaths.contains(configWorktreeURL.path))
        #expect(descriptor.watchedPaths.contains(fixture.gitDirectory.path))
        #expect(descriptor.containsGitMetadataChange(paths: [configWorktreeURL.path]))
        #expect(!descriptor.containsGitMetadataChange(paths: [
            fixture.gitDirectory.appendingPathComponent("info/other").path,
        ]))
    }

    @Test func watchesCaseSensitiveExternalFilesReferenceStore() throws {
        let fixture = try GitRepositoryFixture()
        let externalRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("cmuxgit-external-refs-\(UUID().uuidString)", isDirectory: true)
        let branch = "Feature/CaseSensitive"
        let branchRef = externalRoot
            .appendingPathComponent("refs/heads", isDirectory: true)
            .appendingPathComponent(branch)
        try FileManager.default.createDirectory(
            at: branchRef.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        try String(repeating: "a", count: 40).write(
            to: branchRef,
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeBranch(branch)
        try fixture.writeConfig("""
        [extensions]
            refStorage = files:\(externalRoot.path)
        """)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let result = GitConfigBranchTraversal(
            repository: repository,
            branchContext: .resolved(branch),
            includeConditionalPathsForWatch: true
        ).watchPathResult()

        #expect(result.paths.contains(branchRef.standardizedFileURL.path))
    }

    @Test func readsLinkedWorktreeConfigWhenPresent() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = true
        """)
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config.worktree"),
            atomically: true,
            encoding: .utf8
        )

        #expect(slugs(forDirectory: fixture.root.path) == ["manaflow-ai/cmux"])
    }

    @Test func ignoresStrayWorktreeConfigWhenExtensionIsDisabled() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = false
        """)
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config.worktree"),
            atomically: true,
            encoding: .utf8
        )

        #expect(slugs(forDirectory: fixture.root.path) == [])
    }

    @Test func followsIncludesWhenEnablingWorktreeConfig() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = flags.inc
        """)
        try """
        [extensions]
            worktreeConfig = yes
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("flags.inc"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [remote "upstream"]
            url = https://github.com/manaflow-ai/cmux.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config.worktree"),
            atomically: true,
            encoding: .utf8
        )

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
