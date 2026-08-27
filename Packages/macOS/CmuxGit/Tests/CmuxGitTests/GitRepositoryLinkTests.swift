import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitRepositoryLinkTests {
    @Test(arguments: [
        ("origin\thttps://github.com/manaflow-ai/cmux.git (fetch)\n", "manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux"),
        ("origin\thttp://git.example.com/group/repo.git (fetch)\n", "group/repo", "http://git.example.com/group/repo"),
        ("origin\tgit@gitlab.example.com:group/subgroup/repo.git (fetch)\n", "group/subgroup/repo", "https://gitlab.example.com/group/subgroup/repo"),
        ("origin\tssh://deploy@git.example.com/group/repo.git?token=secret#fragment (fetch)\n", "group/repo", "https://git.example.com/group/repo"),
        ("origin\tgit://bitbucket.example.com/team/repo.git (fetch)\n", "team/repo", "https://bitbucket.example.com/team/repo"),
        ("origin\tssh://git@example.com:2222/group/repo.git (fetch)\n", "group/repo", "https://example.com/group/repo"),
        ("origin\tgit://example.com:9418/group/repo.git (fetch)\n", "group/repo", "https://example.com/group/repo"),
    ])
    func normalizesBrowsableRemote(output: String, displayName: String, url: String) {
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.displayName == displayName)
        #expect(link?.url.absoluteString == url)
    }

    @Test(arguments: [
        ("git@192.168.1.20:username/repo.git", "http://192.168.1.20/username/repo"),
        ("ssh://git@10.0.0.1:22/group/repo.git", "http://10.0.0.1/group/repo"),
        ("git://172.16.0.1:9418/group/repo.git", "http://172.16.0.1/group/repo"),
        ("git@172.31.255.254:group/repo.git", "http://172.31.255.254/group/repo"),
    ])
    func normalizesPrivateIPv4NonHTTPRemotesToHTTP(remoteURL: String, url: String) {
        let output = "origin\t\(remoteURL) (fetch)\n"
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.url.absoluteString == url)
        #expect(link?.url.port == nil)
    }

    @Test(arguments: [
        ("git@172.15.255.255:group/repo.git", "https://172.15.255.255/group/repo"),
        ("ssh://git@172.32.0.1:22/group/repo.git", "https://172.32.0.1/group/repo"),
        ("git://8.8.8.8:9418/group/repo.git", "https://8.8.8.8/group/repo"),
        ("git@127.0.0.1:group/repo.git", "https://127.0.0.1/group/repo"),
        ("ssh://git@169.254.1.1:22/group/repo.git", "https://169.254.1.1/group/repo"),
        ("git@forge.internal:group/repo.git", "https://forge.internal/group/repo"),
        ("git://[fd00::1]:9418/group/repo.git", "https://[fd00::1]/group/repo"),
    ])
    func keepsNonPrivateIPv4NonHTTPRemotesOnHTTPS(remoteURL: String, url: String) {
        let output = "origin\t\(remoteURL) (fetch)\n"
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.url.absoluteString == url)
        #expect(link?.url.port == nil)
    }

    @Test(arguments: [
        "/local/repo.git",
        "../repo",
        "file:///tmp/repo.git",
        "file:/tmp/repo.git",
        "ext::foo",
        "ftp://host/repo.git",
        "ftp:host/repo.git",
        "svn:host/repo.git",
        "custom://host/repo.git",
        "https:///group/repo.git",
        "ssh://git@/group/repo.git",
    ])
    func rejectsNonBrowsableRemote(remoteURL: String) {
        let output = "origin\t\(remoteURL) (fetch)\n"
        #expect(GitMetadataService.repositoryLink(fromGitRemoteVOutput: output) == nil)
    }

    @Test(arguments: [
        ("git@gitlab.example.com:group/repo.git", "https://gitlab.example.com/group/repo"),
        ("git.example.com:group/repo.git", "https://git.example.com/group/repo"),
        ("localhost:group/repo.git", "https://localhost/group/repo"),
        ("work:team/repo.git", "https://work/team/repo"),
    ])
    func preservesUnambiguousSCPRemotes(remoteURL: String, url: String) {
        let output = "origin\t\(remoteURL) (fetch)\n"
        #expect(GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)?.url.absoluteString == url)
    }

    @Test func ignoresPushOnlyRemotes() {
        let output = "origin\thttps://github.com/manaflow-ai/cmux.git (push)\n"
        #expect(GitMetadataService.repositoryLink(fromGitRemoteVOutput: output) == nil)
    }

    @Test func prefersOriginOverUpstream() {
        let output = """
        upstream\thttps://github.com/canonical/cmux.git (fetch)
        origin\thttps://github.com/fork/cmux.git (fetch)
        """
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.remoteName == "origin")
        #expect(link?.displayName == "fork/cmux")
    }

    @Test func prefersUpstreamOverAlphabeticFallback() {
        let output = """
        backup\thttps://github.com/backup/cmux.git (fetch)
        upstream\thttps://github.com/canonical/cmux.git (fetch)
        """
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.remoteName == "upstream")
    }

    @Test func ordersFallbackRemotesCaseInsensitivelyWithCaseSensitiveTieBreak() {
        let output = """
        zebra\thttps://github.com/zebra/cmux.git (fetch)
        Alpha\thttps://github.com/upper/cmux.git (fetch)
        alpha\thttps://github.com/lower/cmux.git (fetch)
        """
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.remoteName == "Alpha")
    }

    @Test func ignoresDuplicateRemoteLines() {
        let output = """
        origin\thttps://github.com/fork/cmux.git (fetch)
        origin\thttps://github.com/fork/cmux.git (fetch)
        upstream\thttps://github.com/canonical/cmux.git (fetch)
        """
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.remoteName == "origin")
        #expect(link?.url.absoluteString == "https://github.com/fork/cmux")
    }

    @Test func fallsThroughInvalidOriginToValidUpstream() {
        let output = """
        origin\tfile:///tmp/cmux.git (fetch)
        upstream\thttps://github.com/manaflow-ai/cmux.git (fetch)
        """
        let link = GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)
        #expect(link?.remoteName == "upstream")
    }

    @Test func attachesRepositoryLinkToWorkspaceMetadata() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
            url = git@gitlab.example.com:group/subgroup/repo.git
        """)

        let metadata = await GitMetadataService().workspaceMetadata(for: fixture.root.path)

        #expect(metadata.repositoryLink?.remoteName == "origin")
        #expect(metadata.repositoryLink?.displayName == "group/subgroup/repo")
        #expect(metadata.repositoryLink?.url.absoluteString == "https://gitlab.example.com/group/subgroup/repo")
    }

    @Test func repositoryLinkCacheInvalidatesWhenConfigStatusChanges() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/first/repo.git
        """)
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let configPath = fixture.gitDirectory.appendingPathComponent("config").path

        let first = await service.workspaceMetadata(for: fixture.root.path)
        #expect(first.repositoryLink?.url.absoluteString == "https://github.com/first/repo")

        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/second/repo.git
        """)
        let changedStatus = GitFileStatus(
            mode: 0o100644,
            size: 99,
            mtimeSeconds: 123,
            mtimeNanoseconds: 456
        )
        reader.overrideStatus(changedStatus, atPath: configPath)

        let second = await service.workspaceMetadata(for: fixture.root.path)
        #expect(second.repositoryLink?.url.absoluteString == "https://github.com/second/repo")
    }

    @Test func repositoryLinkCacheInvalidatesWhenMissingConfigAppears() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let service = GitMetadataService()

        let first = await service.workspaceMetadata(for: fixture.root.path)
        #expect(first.repositoryLink == nil)

        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/appeared/repo.git
        """)

        let second = await service.workspaceMetadata(for: fixture.root.path)
        #expect(second.repositoryLink?.url.absoluteString == "https://github.com/appeared/repo")
    }

    @Test func repositoryLinkCacheInvalidatesWhenSymlinkTargetChanges() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let targetURL = fixture.root.appendingPathComponent("shared-config")
        let configURL = fixture.gitDirectory.appendingPathComponent("config")
        try """
        [remote "origin"]
            url = https://github.com/first/repo.git
        """.write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: configURL.path,
            withDestinationPath: targetURL.path
        )
        let service = GitMetadataService()

        let first = await service.workspaceMetadata(for: fixture.root.path)
        #expect(first.repositoryLink?.url.absoluteString == "https://github.com/first/repo")

        try """
        [remote "origin"]
            url = https://github.com/second/repo.git
        """.write(to: targetURL, atomically: true, encoding: .utf8)

        let second = await service.workspaceMetadata(for: fixture.root.path)
        #expect(second.repositoryLink?.url.absoluteString == "https://github.com/second/repo")
    }

    @Test func repositoryLinkCacheSkipsOversizedDependencySets() async throws {
        let cache = GitRepositoryLinkCache(maximumDependencyPathCount: 1)
        let repository = ResolvedGitRepository(
            workTreeRoot: "/repo",
            gitDirectory: "/repo/.git",
            commonDirectory: "/repo/.git"
        )
        let reader = CountingGitFileStatusReader()
        let configURLs = [
            URL(fileURLWithPath: "/repo/.git/config"),
            URL(fileURLWithPath: "/repo/.git/extra.inc")
        ]

        await cache.store(
            link: nil,
            repository: repository,
            configURLs: configURLs,
            headSignature: "head",
            fileStatusReader: reader
        )

        #expect(await cache.cachedLink(
            repository: repository,
            headSignature: "head",
            fileStatusReader: reader
        ) == nil)
    }

    @Test func repositoryLinkConfigTraversalStopsAtLargeConfigBudget() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig(
            "[remote \"origin\"]\n\turl = https://github.com/deep/repo.git\n"
                + String(repeating: "#", count: 4 * 1024 * 1024 + 1)
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )

        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(repository: repository)

        #expect(!snapshot.isComplete)
        #expect(snapshot.configURLs.count <= 512)
        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func repositoryLinkAppliesInsteadOfRewrite() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [url "ssh://git@github.com/"]
            insteadOf = corp:
        [remote "origin"]
            url = corp:owner/repo.git
        """)

        let metadata = await GitMetadataService().workspaceMetadata(for: fixture.root.path)

        #expect(metadata.repositoryLink?.url.absoluteString == "https://github.com/owner/repo")
    }

    @Test func repositoryLinkCacheInvalidatesWhenOnBranchIncludeChanges() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main", commit: String(repeating: "a", count: 40))
        try fixture.writeConfig("""
        [includeIf "onbranch:main"]
            path = main.inc
        [includeIf "onbranch:feature/*"]
            path = feature.inc
        """)
        try """
        [remote "origin"]
            url = https://github.com/main/repo.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("main.inc"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [remote "origin"]
            url = https://github.com/feature/repo.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("feature.inc"),
            atomically: true,
            encoding: .utf8
        )
        let service = GitMetadataService()

        let main = await service.workspaceMetadata(for: fixture.root.path)
        #expect(main.repositoryLink?.url.absoluteString == "https://github.com/main/repo")

        try fixture.writeBranch("feature/cache", commit: String(repeating: "b", count: 40))

        let feature = await service.workspaceMetadata(for: fixture.root.path)
        #expect(feature.repositoryLink?.url.absoluteString == "https://github.com/feature/repo")
    }

    @Test func worktreeConfigIsIgnoredUntilTheExtensionIsEnabled() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = false
        """)
        try """
        [remote "origin"]
            url = https://github.com/worktree/ignored.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config.worktree"),
            atomically: true,
            encoding: .utf8
        )

        let metadata = await GitMetadataService().workspaceMetadata(for: fixture.root.path)

        #expect(metadata.repositoryLink == nil)
    }

    @Test func enabledWorktreeConfigIsWatchedAndInvalidatesWhenCreated() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [extensions]
            worktreeConfig = true
        """)
        let service = GitMetadataService()

        let initial = await service.workspaceMetadata(for: fixture.root.path)
        #expect(initial.repositoryLink == nil)

        let worktreeConfigURL = fixture.gitDirectory.appendingPathComponent("config.worktree")
        try """
        [remote "origin"]
            url = https://github.com/worktree/enabled.git
        """.write(to: worktreeConfigURL, atomically: true, encoding: .utf8)

        let updated = await service.workspaceMetadata(for: fixture.root.path)
        #expect(updated.repositoryLink?.url.absoluteString == "https://github.com/worktree/enabled")

        let descriptor = try #require(
            await service.watchDescriptor(for: fixture.root.path)
        )
        #expect(descriptor.gitMetadataPaths.contains(worktreeConfigURL.path))
    }

    @Test func resolvesSystemConfigFromGitExecPath() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-prefix-\(UUID().uuidString)", isDirectory: true)
        let execPath = prefix.appendingPathComponent("libexec/git-core", isDirectory: true)
        let systemConfigURL = prefix.appendingPathComponent("etc/gitconfig")
        try FileManager.default.createDirectory(at: execPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: systemConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: prefix) }
        try """
        [remote "origin"]
            url = https://github.com/system/repo.git
        """.write(to: systemConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_EXEC_PATH": execPath.path,
                "GIT_CONFIG_NOSYSTEM": "",
            ]
        )

        #expect(snapshot.configURLs.contains(systemConfigURL.standardizedFileURL))
        #expect(snapshot.remoteVOutput?.contains("https://github.com/system/repo.git") == true)
    }

    @Test func readsXDGGlobalConfigBeforeHomeWhenXDGIsEmpty() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-home-\(UUID().uuidString)", isDirectory: true)
        let xdgConfigURL = home.appendingPathComponent(".config/git/config")
        let legacyConfigURL = home.appendingPathComponent(".gitconfig")
        try FileManager.default.createDirectory(
            at: xdgConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [remote "origin"]
            url = https://github.com/xdg/repo.git
        """.write(to: xdgConfigURL, atomically: true, encoding: .utf8)
        try """
        [remote "origin"]
            url = https://github.com/home/repo.git
        """.write(to: legacyConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": home.path,
                "XDG_CONFIG_HOME": "",
            ]
        )
        let link = try #require(
            snapshot.remoteVOutput.flatMap {
                GitMetadataService.repositoryLink(fromGitRemoteVOutput: $0)
            }
        )

        #expect(link.url.absoluteString == "https://github.com/xdg/repo")
    }

    @Test func emptyRemoteURLResetsInheritedValues() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let includedURL = fixture.root.appendingPathComponent("inherited.inc")
        try """
        [remote "origin"]
            url = https://github.com/inherited/repo.git
        """.write(to: includedURL, atomically: true, encoding: .utf8)
        try """
        [include]
            path = inherited.inc
        [remote "origin"]
            url =
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func worktreeConfigExtensionInIncludedCommonConfigIsHonored() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = worktree-extension.inc
        """)
        try """
        [extensions]
            worktreeConfig = true
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("worktree-extension.inc"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [remote "origin"]
            url = https://github.com/included-worktree/repo.git
        """.write(
            to: fixture.gitDirectory.appendingPathComponent("config.worktree"),
            atomically: true,
            encoding: .utf8
        )

        let metadata = await GitMetadataService().workspaceMetadata(for: fixture.root.path)

        #expect(metadata.repositoryLink?.url.absoluteString == "https://github.com/included-worktree/repo")
    }

    @Test func falseGitConfigNoSystemKeepsConfiguredSystemConfig() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let systemConfigURL = fixture.root.appendingPathComponent("system.gitconfig")
        try """
        [remote "origin"]
            url = https://github.com/system-enabled/repo.git
        """.write(to: systemConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "false",
                "GIT_CONFIG_SYSTEM": systemConfigURL.path,
            ]
        )

        #expect(snapshot.remoteVOutput?.contains("https://github.com/system-enabled/repo.git") == true)
    }

    @Test func emptyGitConfigSystemDisablesDefaultSystemConfig() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-empty-system-\(UUID().uuidString)", isDirectory: true)
        let execPath = prefix.appendingPathComponent("libexec/git-core", isDirectory: true)
        let systemConfigURL = prefix.appendingPathComponent("etc/gitconfig")
        try FileManager.default.createDirectory(at: execPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: systemConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: prefix) }
        try """
        [remote "origin"]
            url = https://github.com/ignored-system/repo.git
        """.write(to: systemConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "false",
                "GIT_CONFIG_SYSTEM": "",
                "GIT_EXEC_PATH": execPath.path,
            ]
        )

        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func runtimeGitConfigOverridesFailClosed() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/file/repo.git
        """)
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )

        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "remote.origin.url",
                "GIT_CONFIG_VALUE_0": "https://github.com/runtime/repo.git",
            ]
        )

        #expect(!snapshot.isComplete)
        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func devNullIncludeDoesNotInvalidateTheConfigSnapshot() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("""
        [include]
            path = /dev/null
        [remote "origin"]
            url = https://github.com/dev-null-safe/repo.git
        """)
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )

        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        )

        #expect(snapshot.isComplete)
        #expect(snapshot.remoteVOutput?.contains("https://github.com/dev-null-safe/repo.git") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingIncludeDiscoveryHasAPathBudget() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("many-missing.gitconfig")
        let includes = (0..<40_000).map { index in
            """
            [include]
                path = missing-\(index).inc
            """
        }
        try includes.joined(separator: "\n")
            .write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let reader = CountingGitFileStatusReader()
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )

        _ = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            fileStatusReader: reader,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(reader.totalCallCount < 10_000)
    }

    @Test func emptyGitConfigGlobalDisablesDefaultGlobalFiles() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-empty-global-\(UUID().uuidString)", isDirectory: true)
        let homeConfigURL = home.appendingPathComponent(".gitconfig")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [remote "origin"]
            url = https://github.com/ignored-global/repo.git
        """.write(to: homeConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": "",
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": home.path,
            ]
        )

        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func hasConfigIncludeIfMatchesRemoteDeclaredLater() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let includedURL = fixture.root.appendingPathComponent("hasconfig.inc")
        try """
        [url "https://github.com/"]
            insteadOf = corp:
        """.write(to: includedURL, atomically: true, encoding: .utf8)
        try """
        [includeIf "hasconfig:remote.*.url:https://example.com/**"]
            path = hasconfig.inc
        [remote "trigger"]
            url = https://example.com/trigger.git
        [remote "origin"]
            url = corp:owner/repo.git
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(snapshot.remoteVOutput?.contains("https://github.com/owner/repo.git") == true)
    }

    @Test func configuredHomeResolvesTildeIncludes() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-tilde-home-\(UUID().uuidString)", isDirectory: true)
        let globalConfigURL = home.appendingPathComponent(".gitconfig")
        let includedURL = home.appendingPathComponent("shared.inc")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [include]
            path = ~/shared.inc
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        [remote "origin"]
            url = https://github.com/tilde-home/repo.git
        """.write(to: includedURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": home.path,
            ]
        )

        #expect(snapshot.remoteVOutput?.contains("https://github.com/tilde-home/repo.git") == true)
    }

    @Test func hasConfigDiscoveryScansMatchingGitdirIncludes() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let conditionalURL = fixture.root.appendingPathComponent("conditional.inc")
        let hasConfigURL = fixture.root.appendingPathComponent("hasconfig.inc")
        try """
        [remote "conditional"]
            url = https://conditional.example/trigger.git
        """.write(to: conditionalURL, atomically: true, encoding: .utf8)
        try """
        [url "https://github.com/conditional-hasconfig/"]
            insteadOf = corp:
        """.write(to: hasConfigURL, atomically: true, encoding: .utf8)
        try """
        [includeIf "gitdir:\(fixture.gitDirectory.path)/"]
            path = conditional.inc
        [includeIf "hasconfig:remote.*.url:https://conditional.example/**"]
            path = hasconfig.inc
        [remote "origin"]
            url = corp:repo.git
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(snapshot.remoteVOutput?.contains("https://github.com/conditional-hasconfig/repo.git") == true)
    }

    @Test func hasConfigDiscoveryHonorsEmptyRemoteURLReset() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let includedURL = fixture.root.appendingPathComponent("reset.inc")
        try """
        [url "https://github.com/"]
            insteadOf = corp:
        """.write(to: includedURL, atomically: true, encoding: .utf8)
        try """
        [remote "trigger"]
            url = https://reset.example/repository.git
            url =
        [includeIf "hasconfig:remote.*.url:https://reset.example/**"]
            path = reset.inc
        [remote "origin"]
            url = corp:owner/repo.git
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(snapshot.configURLs.contains(includedURL.standardizedFileURL))
        #expect(snapshot.remoteVOutput?.contains("https://github.com/owner/repo.git") == true)
    }

    @Test func remoteURLInHasConfigIncludedFileFailsClosed() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let includedURL = fixture.root.appendingPathComponent("invalid-remote.inc")
        try """
        [remote "forbidden"]
            url = https://github.com/forbidden/repository.git
        """.write(to: includedURL, atomically: true, encoding: .utf8)
        try """
        [includeIf "hasconfig:remote.*.url:https://trigger.example/**"]
            path = invalid-remote.inc
        [remote "trigger"]
            url = https://trigger.example/repository.git
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(!snapshot.isComplete)
    }

    @Test func unsupportedWorktreeIncludeIfFailsClosed() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let includedURL = fixture.root.appendingPathComponent("worktree.inc")
        try """
        [remote "origin"]
            url = https://github.com/worktree-conditional/repo.git
        """.write(to: includedURL, atomically: true, encoding: .utf8)
        try """
        [includeIf "worktree:\(fixture.root.path)/"]
            path = worktree.inc
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(snapshot.remoteVOutput == nil)
    }

    @Test func repositoryLinkUsesFirstFetchURLForDuplicateRemoteURLs() {
        let output = """
        origin\thttps://github.com/old/repo.git (fetch)
        origin\thttps://github.com/new/repo.git (fetch)
        """

        #expect(
            GitMetadataService.repositoryLink(fromGitRemoteVOutput: output)?.url.absoluteString
                == "https://github.com/old/repo"
        )
    }

    @Test func hasConfigMatchingStopsAtItsOperationBudget() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let remoteSections = (0..<257).map { index in
            """
            [remote "remote-\(index)"]
                url = https://example.com/repository-\(index).git
            """
        }
        let conditions = (0..<256).map { index in
            """
            [includeIf "hasconfig:remote.*.url:https://unmatched-\(index).example/**"]
                path = unmatched-\(index).inc
            """
        }
        try (remoteSections + conditions)
            .joined(separator: "\n")
            .write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(!snapshot.isComplete)
    }

    @Test func urlRewriteMatchingStopsAtItsOperationBudget() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let globalConfigURL = fixture.root.appendingPathComponent("global.gitconfig")
        let rewrites = (0..<256).map { index in
            """
            [url "https://github.com/rewrite-\(index)/"]
                insteadOf = rewrite-\(index):
            """
        }
        let remotes = (0..<257).map { index in
            """
            [remote "remote-\(index)"]
                url = unmatched-\(index):repository.git
            """
        }
        try (rewrites + remotes)
            .joined(separator: "\n")
            .write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let snapshot = GitMetadataService.gitRemoteConfigSnapshot(
            repository: repository,
            environment: [
                "GIT_CONFIG_GLOBAL": globalConfigURL.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ]
        )

        #expect(!snapshot.isComplete)
    }
}
