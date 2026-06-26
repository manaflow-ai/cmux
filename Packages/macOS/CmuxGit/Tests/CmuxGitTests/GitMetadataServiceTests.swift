import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitMetadataServiceTests {
    // MARK: Repository resolution

    @Test func resolvesNormalRepositoryFromNestedDirectory() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let nested = fixture.root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let repo = try #require(GitMetadataService.resolveGitRepository(containing: nested.path))
        #expect(repo.workTreeRoot == fixture.root.standardizedFileURL.path)
        #expect(repo.gitDirectory == fixture.gitDirectory.standardizedFileURL.path)
        #expect(repo.commonDirectory == fixture.gitDirectory.standardizedFileURL.path)
    }

    @Test func returnsNilOutsideAnyRepository() {
        let repo = GitMetadataService.resolveGitRepository(
            containing: FileManager.default.temporaryDirectory.path
        )
        // The temp dir (/var/folders/...) is never inside a git repository;
        // resolution must walk to the filesystem root and return nil.
        #expect(repo == nil)
    }

    @Test func dotGitFilePointerResolvesGitDirectory() throws {
        // Worktree-style: .git is a file pointing at a sibling git directory.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-gitfile-\(UUID().uuidString)", isDirectory: true)
        let worktree = base.appendingPathComponent("wt", isDirectory: true)
        let realGitDir = base.appendingPathComponent("realgit", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try "gitdir: \(realGitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let repo = try #require(GitMetadataService.resolveGitRepository(containing: worktree.path))
        #expect(repo.workTreeRoot == worktree.standardizedFileURL.path)
        #expect(repo.gitDirectory == realGitDir.standardizedFileURL.path)
    }

    @Test(arguments: [
        ("/", "/"),
        // Older Foundation can report /.. as the parent of /, or escape above
        // root entirely; the search must still terminate in both cases.
        ("/", "/.."),
        ("/..", "/../.."),
    ])
    func rootVariantsStopRepositorySearch(current: String, parent: String) {
        #expect(GitMetadataService.shouldStopGitRepositorySearch(
            currentURL: URL(fileURLWithPath: current),
            parentURL: URL(fileURLWithPath: parent)
        ))
    }

    @Test func nonRootParentDoesNotStopSearch() {
        #expect(!GitMetadataService.shouldStopGitRepositorySearch(
            currentURL: URL(fileURLWithPath: "/Users/someone/project"),
            parentURL: URL(fileURLWithPath: "/Users/someone")
        ))
    }

    // MARK: Branch + metadata

    @Test func workspaceMetadataReadsBranch() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feature/x")
        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isRepository)
        #expect(meta.branch == "feature/x")
        #expect(meta.headSignature != nil)
    }

    @Test func workspaceMetadataReportsNotARepository() async {
        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: "/definitely/not/a/repo/\(UUID().uuidString)")
        #expect(meta == .notARepository)
    }

    @Test func detachedHeadHasNoBranch() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeDetachedHead(commit: String(repeating: "1", count: 40))
        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isRepository)
        #expect(meta.branch == nil)
    }

    // MARK: Dirty detection (index v2)

    @Test func cleanWorkingTreeIsNotDirty() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isRepository)
        #expect(meta.isDirty == false)
        #expect(meta.indexSignature != nil)
        #expect(meta.indexContentSignature != nil)
    }

    @Test func modifiedSizeMarksDirty() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        var entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        entry.size += 100 // index disagrees with the working tree
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isDirty)
    }

    @Test func missingTrackedFileMarksDirty() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = GitIndexFixture.Entry(path: "ghost.txt", size: 3)
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isDirty)
    }

    @Test func assumeUnchangedEntryIsIgnoredForDirtiness() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        var entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        entry.size += 100
        entry.assumeUnchanged = true // excluded from the dirty check
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

        let service = GitMetadataService()
        let meta = await service.workspaceMetadata(for: fixture.root.path)
        #expect(meta.isDirty == false)
    }

    @Test func unchangedIndexAndGenerationReusesTrackedChangesSnapshot() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let generation = GitTrackedPathEventGeneration(namespace: UUID(), generation: 10)

        let first = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation
        )
        let second = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation
        )

        #expect(first == second)
        #expect(reader.callCount(atPath: filePath) == 1)
    }

    @Test func trackedPathEventGenerationRescansAndDetectsUnstagedEdit() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let fileURL = fixture.root.appendingPathComponent("file.txt")
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let namespace = UUID()

        let clean = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: GitTrackedPathEventGeneration(namespace: namespace, generation: 20)
        )
        try "hello, dirty".write(to: fileURL, atomically: true, encoding: .utf8)
        let dirty = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: GitTrackedPathEventGeneration(namespace: namespace, generation: 21)
        )

        #expect(clean.isDirty == false)
        #expect(dirty.isDirty)
        #expect(reader.callCount(atPath: fileURL.path) == 2)
    }

    @Test func sameGenerationFromIndependentOwnersRescansAndDetectsUnstagedEdit() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let fileURL = fixture.root.appendingPathComponent("file.txt")
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let firstOwner = UUID()
        let secondOwner = UUID()

        let clean = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: GitTrackedPathEventGeneration(namespace: firstOwner, generation: 1)
        )
        try "hello, dirty".write(to: fileURL, atomically: true, encoding: .utf8)
        let dirty = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: GitTrackedPathEventGeneration(namespace: secondOwner, generation: 1)
        )

        #expect(clean.isDirty == false)
        #expect(dirty.isDirty)
        #expect(reader.callCount(atPath: fileURL.path) == 2)
    }

    @Test func indexStatChangeRescansTrackedEntries() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let indexPath = fixture.gitDirectory.appendingPathComponent("index").path
        let filePath = fixture.root.appendingPathComponent("file.txt").path
        let reader = CountingGitFileStatusReader()
        let service = GitMetadataService(fileStatusReader: reader)
        let generation = GitTrackedPathEventGeneration(namespace: UUID(), generation: 30)

        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation
        )
        var changedIndexStatus = try #require(reader.statusWithoutRecording(atPath: indexPath))
        changedIndexStatus = GitFileStatus(
            mode: changedIndexStatus.mode,
            size: changedIndexStatus.size,
            mtimeSeconds: changedIndexStatus.mtimeSeconds + 1,
            mtimeNanoseconds: changedIndexStatus.mtimeNanoseconds
        )
        reader.overrideStatus(changedIndexStatus, atPath: indexPath)
        _ = await service.gitTrackedChangesSnapshot(
            repository: repository,
            trackedPathEventGeneration: generation
        )

        #expect(reader.callCount(atPath: filePath) == 2)
    }

    // MARK: Index v4 prefix-compression

    @Test func indexVersionFourDecodesPrefixCompressedPaths() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entries = [
            GitIndexFixture.Entry(path: "src/alpha.swift"),
            GitIndexFixture.Entry(path: "src/alphabet.swift"), // shares "src/alpha" prefix
            GitIndexFixture.Entry(path: "src/beta.swift"),
        ]
        try fixture.writeIndex(GitIndexFixture(version: 4, entries: entries))

        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        let snapshot = try #require(GitMetadataService.gitIndexSnapshot(indexURL: indexURL))
        #expect(snapshot.entries.map(\.path) == ["src/alpha.swift", "src/alphabet.swift", "src/beta.swift"])
    }

    @Test func indexVersionFourMultiByteStripLength() throws {
        // A long shared prefix forces a multi-byte strip-length varint.
        let longPrefix = String(repeating: "deep/", count: 40) // 200 chars
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let entries = [
            GitIndexFixture.Entry(path: longPrefix + "first.txt"),
            GitIndexFixture.Entry(path: longPrefix + "second.txt"),
        ]
        try fixture.writeIndex(GitIndexFixture(version: 4, entries: entries))

        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        let snapshot = try #require(GitMetadataService.gitIndexSnapshot(indexURL: indexURL))
        #expect(snapshot.entries.map(\.path) == [longPrefix + "first.txt", longPrefix + "second.txt"])
    }

    @Test func indexHexFieldsDecodeWithoutChangingObjectAndSignatureText() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let objectID = "000102030405060708090a0b0c0d0e0f10111213"
        let trailer = Array(UInt8(0x14)...UInt8(0x27))
        try fixture.writeIndex(GitIndexFixture(
            version: 2,
            entries: [
                GitIndexFixture.Entry(path: "tracked.txt", objectID: objectID),
            ],
            trailer: trailer
        ))

        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        let snapshot = try #require(GitMetadataService.gitIndexSnapshot(indexURL: indexURL))
        #expect(snapshot.entries.map(\.objectID) == [objectID])
        #expect(snapshot.signature == "1415161718191a1b1c1d1e1f2021222324252627")
    }

    // MARK: Content signature stability

    @Test func contentSignatureIgnoresStatOnlyChanges() {
        let base = GitIndexEntryStat(
            path: "a.txt", mode: 0o100644, objectID: String(repeating: "b", count: 40),
            mtimeSeconds: 10, mtimeNanoseconds: 0, size: 5
        )
        let restated = GitIndexEntryStat(
            path: "a.txt", mode: 0o100644, objectID: String(repeating: "b", count: 40),
            mtimeSeconds: 999, mtimeNanoseconds: 7, size: 9999
        )
        let lhs = GitMetadataService.gitIndexContentSignature(entries: [base])
        let rhs = GitMetadataService.gitIndexContentSignature(entries: [restated])
        #expect(lhs == rhs) // path + mode + objectID only
    }

    @Test func contentSignatureChangesWithObjectID() {
        let base = GitIndexEntryStat(
            path: "a.txt", mode: 0o100644, objectID: String(repeating: "b", count: 40),
            mtimeSeconds: 1, mtimeNanoseconds: 0, size: 0
        )
        let changed = GitIndexEntryStat(
            path: "a.txt", mode: 0o100644, objectID: String(repeating: "c", count: 40),
            mtimeSeconds: 1, mtimeNanoseconds: 0, size: 0
        )
        #expect(
            GitMetadataService.gitIndexContentSignature(entries: [base])
                != GitMetadataService.gitIndexContentSignature(entries: [changed])
        )
    }

    // MARK: Watched paths

    @Test func watchedPathsIncludeHeadIndexRefsAndConfig() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeConfig("[core]\n\trepositoryformatversion = 0\n")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: []))

        let service = GitMetadataService()
        let paths = try #require(await service.watchedPaths(for: fixture.root.path))
        #expect(paths == paths.sorted())
        #expect(paths.contains(fixture.gitDirectory.appendingPathComponent("HEAD").standardizedFileURL.path))
        #expect(paths.contains(fixture.gitDirectory.appendingPathComponent("index").standardizedFileURL.path))
        #expect(paths.contains(fixture.gitDirectory.appendingPathComponent("config").standardizedFileURL.path))
        #expect(paths.contains(fixture.root.standardizedFileURL.path))
    }

    @Test func watchedPathsNilOutsideRepository() async {
        let service = GitMetadataService()
        let paths = await service.watchedPaths(for: "/nope/\(UUID().uuidString)")
        #expect(paths == nil)
    }

    // MARK: Parsing fidelity (issue #5359)

    @Test func indexWithTraversalPathIsRejected() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "ok.txt"),
            GitIndexFixture.Entry(path: "../escape.txt"),
        ]))
        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) == nil)
    }

    @Test func indexWithAbsolutePathIsRejected() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "/etc/passwd"),
        ]))
        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) == nil)
    }

    @Test func symbolicRefEscapingGitDirectoryIsNotRead() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        // Plant a readable file OUTSIDE the git directory that an escaping ref
        // name would resolve to; the lookup must refuse to read it.
        let outside = fixture.root.appendingPathComponent("outside-ref")
        try String(repeating: "e", count: 40).write(to: outside, atomically: true, encoding: .utf8)
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        #expect(GitMetadataService.gitRefValue(repository: repository, refName: "../outside-ref") == nil)
        // Sanity: a legitimate ref still resolves.
        #expect(GitMetadataService.gitRefValue(repository: repository, refName: "refs/heads/main") != nil)
    }

    @Test func watchedPathsRecurseIntoNestedSubmodules() throws {
        let parent = try GitRepositoryFixture()
        try parent.writeBranch("main")
        let commit = String(repeating: "2", count: 40)

        // parent -> vendor/mid -> vendor/mid/deep (gitlinks at two depths)
        let midRoot = parent.root.appendingPathComponent("vendor/mid", isDirectory: true)
        let midGit = midRoot.appendingPathComponent(".git", isDirectory: true)
        let deepRoot = midRoot.appendingPathComponent("deep", isDirectory: true)
        let deepGit = deepRoot.appendingPathComponent(".git", isDirectory: true)
        for dir in [midGit, deepGit] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("refs/heads"),
                withIntermediateDirectories: true
            )
            try "\(commit)\n".write(to: dir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
        // mid's index records deep as a gitlink; parent's records mid.
        try GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "deep", mode: 0o160000, objectID: commit, size: 0),
        ]).data().write(to: midGit.appendingPathComponent("index"))
        try parent.writeIndex(GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "vendor/mid", mode: 0o160000, objectID: commit, size: 0),
        ]))

        let paths = try #require(GitMetadataService.workspaceGitMetadataWatchedPaths(for: parent.root.path))
        #expect(paths.contains(midGit.appendingPathComponent("HEAD").standardizedFileURL.path))
        #expect(paths.contains(deepGit.appendingPathComponent("HEAD").standardizedFileURL.path),
                "nested submodule metadata must be watched")
    }

    // MARK: Execution contract

    /// Pins the SE-0338 contract the service relies on: a `nonisolated async`
    /// method awaited from the main actor runs on the global concurrent executor,
    /// not the main thread. If CmuxGit ever adopts `NonisolatedNonsendingByDefault`,
    /// this fails — annotate the reads `@concurrent` to restore off-main execution.
    @MainActor @Test func nonisolatedAsyncReadsRunOffTheMainThread() async {
        #expect(pthread_main_np() != 0) // we start on the main actor's thread
        let hopped = await GitMetadataService().executionHopsOffCallersThread()
        #expect(hopped, "nonisolated async must hop off the caller's thread (SE-0338)")
    }
}
