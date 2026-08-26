import Darwin
import Foundation
import Testing
@testable import CmuxGit

private nonisolated struct UserPathGitProbe: GitExecutableFileProbing {
    func isExecutableFile(atPath path: String) -> Bool {
        path == "/Users/cmux-tests/.local/bin/git"
    }
}

private nonisolated struct SystemGitOnlyProbe: GitExecutableFileProbing {
    func isExecutableFile(atPath path: String) -> Bool {
        path == "/usr/bin/git" || path == "/Library/Developer/CommandLineTools/usr/bin/git"
    }
}

private nonisolated struct NeverDirectoryProbe: GitReferenceStorageProbing {
    func isDirectory(atPath _: String) -> Bool { false }
}

@Suite struct ReftableGitMetadataTests {
    @Test func referenceResolverRetainsAbsoluteUserPathGitCandidates() {
        let userGitDirectory = "/Users/cmux-tests/.local/bin"
        let resolver = SystemGitExecutableResolver(
            environment: [
                "PATH": "\(userGitDirectory):/nix/var/nix/profiles/default/bin:/Applications/Xcode.app/Contents/Developer/usr/bin",
            ],
            fileProbe: UserPathGitProbe()
        )

        let candidates = resolver.referenceExecutableURLs().map(\.path)

        #expect(candidates.contains(userGitDirectory + "/git"))
    }

    @Test func referenceResolverRetainsSystemFallbackSlots() {
        let resolver = SystemGitExecutableResolver(
            environment: [
                "PATH": "/Users/cmux-tests/one:/Users/cmux-tests/two:/Users/cmux-tests/three",
            ],
            fileProbe: SystemGitOnlyProbe()
        )

        let candidates = resolver.referenceExecutableURLs().map(\.path)

        #expect(candidates.contains("/usr/bin/git"))
        #expect(candidates.contains("/Library/Developer/CommandLineTools/usr/bin/git"))
    }

    @Test func failedReftablePlumbingRemainsMarkedAsPlumbing() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let reftableURL = fixture.gitDirectory.appendingPathComponent("reftable", isDirectory: true)
        try FileManager.default.createDirectory(at: reftableURL, withIntermediateDirectories: true)
        try "".write(
            to: reftableURL.appendingPathComponent("tables.list"),
            atomically: true,
            encoding: .utf8
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [:])
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .unreadable)
        #expect(snapshot.usesGitPlumbing)
    }

    @Test func injectedReferenceStorageProbeControlsBackendDetection() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let reftableURL = fixture.gitDirectory.appendingPathComponent("reftable", isDirectory: true)
        try FileManager.default.createDirectory(at: reftableURL, withIntermediateDirectories: true)
        try "".write(
            to: reftableURL.appendingPathComponent("tables.list"),
            atomically: true,
            encoding: .utf8
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [:]),
            storageProbe: NeverDirectoryProbe()
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .branch("main"))
        #expect(!snapshot.usesGitPlumbing)
    }

    /// Reproduces a linked reftable worktree whose HEAD contains `.invalid`.
    @Test func metadataUsesGitResolvedWorktreeBranchAndWatchesReftableStorage() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let repository = fixture.root.appendingPathComponent("repository", isDirectory: true)
        let worktree = fixture.root.appendingPathComponent("worktree", isDirectory: true)
        let initialBranch = "feature/reftable-sidebar"
        let nextBranch = "feature/reftable-sidebar-next"

        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=main", repository.path,
        ])
        try fixture.git([
            "-C", repository.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "baseline",
        ])
        try fixture.git([
            "-C", repository.path,
            "worktree", "add", "-b", initialBranch, worktree.path,
        ])

        let resolved = try #require(GitMetadataService.resolveGitRepository(containing: worktree.path))
        let head = try String(
            contentsOf: URL(fileURLWithPath: resolved.gitDirectory).appendingPathComponent("HEAD"),
            encoding: .utf8
        )
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "ref: refs/heads/.invalid")

        let service = GitMetadataService()
        let initialMetadata = await service.workspaceMetadata(for: worktree.path)
        #expect(initialMetadata.branch == initialBranch)
        #expect(await service.checkedOutBranch(forDirectory: worktree.path) == .branch(initialBranch))

        let descriptor = try #require(await service.watchDescriptor(for: worktree.path))
        let worktreeReftable = URL(fileURLWithPath: resolved.gitDirectory)
            .appendingPathComponent("reftable", isDirectory: true)
            .standardizedFileURL.path
        let commonReftable = URL(fileURLWithPath: resolved.commonDirectory)
            .appendingPathComponent("reftable", isDirectory: true)
            .standardizedFileURL.path
        #expect(descriptor.watchedPaths.contains(worktreeReftable))
        #expect(descriptor.watchedPaths.contains(commonReftable))
        #expect(descriptor.containsGitMetadataChange(
            paths: [URL(fileURLWithPath: worktreeReftable).appendingPathComponent("tables.list").path]
        ))

        try fixture.git([
            "-C", worktree.path,
            "switch", "-c", nextBranch,
        ])
        let nextMetadata = await service.workspaceMetadata(for: worktree.path)
        #expect(nextMetadata.branch == nextBranch)
        #expect(nextMetadata.headSignature != initialMetadata.headSignature)
    }

    @Test func unbornReftableBranchKeepsItsBranchIdentity() throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let repositoryRoot = fixture.root.appendingPathComponent("unborn", isDirectory: true)
        let branch = "feature/unborn-reftable"
        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=\(branch)", repositoryRoot.path,
        ])

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: repositoryRoot.path)
        )
        let snapshot = SystemGitReferenceReader().snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .branch(branch))
        #expect(snapshot.currentCommit == nil)
    }

    /// Uses plumbing when a generated config exceeds the bounded backend scan.
    @Test func oversizedReferenceConfigFallsBackToGitPlumbing() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch(".invalid")
        try fixture.writeConfig(
            "[core]\n" + String(repeating: "generated = value\n", count: 70_000)
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let commit = String(repeating: "a", count: 40)
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [
                ["symbolic-ref", "--quiet", "HEAD"]: FakeWorkspaceChangesGitRunner.result(
                    "refs/heads/feature/large-config\n"
                ),
                [
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    "refs/heads/feature/large-config^{commit}",
                ]: FakeWorkspaceChangesGitRunner.result("\(commit)\n"),
            ])
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == GitCheckedOutBranch.branch("feature/large-config"))
        #expect(snapshot.currentCommit == commit)
    }

    @Test func incompleteQuickBackendScanDoesNotTrustLooseRefs() throws {
        let fixture = try GitRepositoryFixture()
        let looseCommit = String(repeating: "f", count: 40)
        try fixture.writeBranch("main", commit: looseCommit)
        try fixture.writeConfig("""
        [include]
            path = backend.inc
        """)
        try """
        [extensions]
            refStorage = reftable
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("backend.inc"),
            atomically: true,
            encoding: .utf8
        )

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let plumbingCommit = String(repeating: "a", count: 40)
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [
                ["symbolic-ref", "--quiet", "HEAD"]: FakeWorkspaceChangesGitRunner.result(
                    "refs/heads/from-plumbing\n"
                ),
                [
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    "refs/heads/from-plumbing^{commit}",
                ]: FakeWorkspaceChangesGitRunner.result("\(plumbingCommit)\n"),
            ])
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .branch("from-plumbing"))
        #expect(snapshot.currentCommit == plumbingCommit)
    }

    @Test func oversizedPackedRefsUseBoundedGitPlumbing() throws {
        let fixture = try GitRepositoryFixture()
        try "ref: refs/heads/main\n".write(
            to: fixture.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try (String(repeating: "# generated\n", count: 120_000) + "\n").write(
            to: fixture.gitDirectory.appendingPathComponent("packed-refs"),
            atomically: true,
            encoding: .utf8
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let plumbingCommit = String(repeating: "b", count: 40)
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [
                ["symbolic-ref", "--quiet", "HEAD"]: FakeWorkspaceChangesGitRunner.result(
                    "refs/heads/from-plumbing\n"
                ),
                [
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    "refs/heads/from-plumbing^{commit}",
                ]: FakeWorkspaceChangesGitRunner.result("\(plumbingCommit)\n"),
            ])
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .branch("from-plumbing"))
        #expect(snapshot.currentCommit == plumbingCommit)
    }

    /// Keeps ambient Git repository overrides from redirecting plumbing reads.
    @Test func plumbingIgnoresAmbientRepositorySelection() throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let intended = fixture.root.appendingPathComponent("intended", isDirectory: true)
        let unrelated = fixture.root.appendingPathComponent("unrelated", isDirectory: true)
        let intendedBranch = "feature/intended"

        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=\(intendedBranch)", intended.path,
        ])
        try fixture.git([
            "-C", intended.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "intended",
        ])
        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=feature/unrelated", unrelated.path,
        ])
        try fixture.git([
            "-C", unrelated.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "unrelated",
        ])

        let intendedRepository = try #require(
            GitMetadataService.resolveGitRepository(containing: intended.path)
        )
        let unrelatedRepository = try #require(
            GitMetadataService.resolveGitRepository(containing: unrelated.path)
        )
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = unrelatedRepository.gitDirectory
        environment["GIT_WORK_TREE"] = unrelated.path
        environment["GIT_COMMON_DIR"] = unrelatedRepository.commonDirectory
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "core.worktree"
        environment["GIT_CONFIG_VALUE_0"] = unrelated.path
        let reader = SystemGitReferenceReader(
            runner: SystemWorkspaceChangesGitRunner(environment: environment)
        )

        let snapshot = reader.snapshot(repository: intendedRepository)

        #expect(snapshot.checkedOutBranch == .branch(intendedBranch))
    }

    @Test func plumbingFallsBackWhenTheFirstGitCannotReadReftable() throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let repositoryRoot = fixture.root.appendingPathComponent("repository", isDirectory: true)
        let worktree = fixture.root.appendingPathComponent("worktree", isDirectory: true)
        let branch = "feature/reftable-fallback"

        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=main", repositoryRoot.path,
        ])
        try fixture.git([
            "-C", repositoryRoot.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "baseline",
        ])
        try fixture.git([
            "-C", repositoryRoot.path,
            "worktree", "add", "-b", branch, worktree.path,
        ])

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: worktree.path)
        )
        let snapshot = SystemGitReferenceReader(runners: [
            SystemWorkspaceChangesGitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false")),
            SystemWorkspaceChangesGitRunner(executableURL: fixture.gitExecutableURL),
        ]).snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == .branch(branch))
    }

    @Test func nonRegularReferenceStorageConfigIsRejectedBeforeRead() throws {
        let fixture = try GitRepositoryFixture()
        let configURL = fixture.gitDirectory.appendingPathComponent("config")
        let fifoResult = configURL.path.withCString { path in
            mkfifo(path, mode_t(0o600))
        }
        #expect(fifoResult == 0)
        defer {
            configURL.path.withCString { path in
                _ = Darwin.unlink(path)
            }
        }

        let result = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [:])
        ).boundedReferenceStorageConfig(at: configURL)

        #expect(result.contents == nil)
        #expect(!result.isOversized)
    }
}
