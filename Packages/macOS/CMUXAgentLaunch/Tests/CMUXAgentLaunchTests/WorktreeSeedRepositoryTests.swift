import Foundation
import Testing
import CMUXAgentLaunch

/// A real directory tree in a temporary location, removed when the test ends.
///
/// A class rather than a struct so `deinit` does the cleanup: the tests can hand
/// the tree to a helper without thinking about ownership.
final class WorktreeSeedTemporaryTree {
    let root: URL

    init(_ name: String = "worktree-seed") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relativePath: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func symlink(_ relativePath: String, to target: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        return url
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("worktreeinclude on a real tree")
struct WorktreeSeedRepositoryTests {
    @Test func aRepositoryWithoutTheFileReportsNothingRatherThanFailing() throws {
        let tree = try WorktreeSeedTemporaryTree()
        #expect(try WorktreeSeedRepository(root: tree.root).includeFile() == nil)
    }

    @Test func theFileIsReadFromTheRepositoryRoot() throws {
        let tree = try WorktreeSeedTemporaryTree()
        try tree.file(".worktreeinclude", "# seed\n.env\nlink node_modules\n")
        let file = try WorktreeSeedRepository(root: tree.root).includeFile()
        #expect(file?.patterns.map(\.glob) == [".env", "node_modules"])
    }

    @Test func aListingSeparatesFilesFromDirectories() throws {
        let tree = try WorktreeSeedTemporaryTree()
        try tree.file(".env")
        _ = try tree.directory("node_modules")
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        #expect(listing.map(\.name) == [".env", "node_modules"])
        #expect(listing.map(\.isDirectory) == [false, true])
        #expect(listing.allSatisfy { !$0.escapesRepository })
    }

    @Test func aSymlinkInsideTheRepositoryIsNotAnEscape() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let target = try tree.file("real/.env")
        try tree.symlink("link-to-env", to: target)
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "link-to-env" })
        #expect(!entry.escapesRepository)
    }

    @Test func aSymlinkOutOfTheRepositoryIsAnEscape() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let outside = try WorktreeSeedTemporaryTree("outside")
        let target = try outside.file("secrets.env")
        try tree.symlink("secrets.env", to: target)
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "secrets.env" })
        #expect(entry.escapesRepository)
    }

    @Test func aDanglingSymlinkOutOfTheRepositoryIsAnEscape() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let target = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/secret")
        try tree.symlink("gone", to: target)
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "gone" })
        #expect(entry.escapesRepository)
    }

    @Test func aChainedSymlinkOutOfTheRepositoryIsAnEscape() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let outside = try WorktreeSeedTemporaryTree("outside")
        let target = try outside.file("secret")
        try tree.symlink("redirect", to: target)
        try tree.symlink("selected", to: tree.root.appendingPathComponent("redirect"))
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "selected" })
        #expect(entry.escapesRepository)
    }

    @Test func aSymlinkedTargetParentDoesNotHideAnEscapingLeaf() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let outside = try WorktreeSeedTemporaryTree("outside")
        let target = try outside.file("secret")
        let directory = try tree.directory("config")
        try tree.symlink("config/redirect", to: target)
        try tree.symlink("alias", to: directory)
        try tree.symlink("selected", to: tree.root.appendingPathComponent("alias/redirect"))
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "selected" })
        #expect(entry.escapesRepository)
    }

    @Test func aValidSymlinkChainCanRevisitAnAlias() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let directory = try tree.directory("real")
        try tree.file("real/file")
        try tree.symlink("alias", to: directory)
        try tree.symlink("real/redirect", to: tree.root.appendingPathComponent("alias/file"))
        try tree.symlink("selected", to: tree.root.appendingPathComponent("alias/redirect"))
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "selected" })
        #expect(!entry.escapesRepository)
    }

    @Test func aDanglingSymlinkInsideTheRepositoryIsNotAnEscape() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let target = tree.root.appendingPathComponent("future/secret")
        try tree.symlink("future-link", to: target)
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "future-link" })
        #expect(!entry.escapesRepository)
    }

    @Test func aSiblingDirectoryWithTheRootAsAPrefixIsOutside() throws {
        let parent = try WorktreeSeedTemporaryTree("prefix")
        let root = try parent.directory("repo")
        let sibling = try parent.directory("repo-backup")
        let target = sibling.appendingPathComponent(".env")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".env").path,
            withDestinationPath: target.path
        )
        let entry = try #require(WorktreeSeedRepository(root: root).listing("").first)
        #expect(entry.escapesRepository)
    }

    @Test func aSymlinkToADirectoryIsALeaf() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let target = try tree.directory("real-modules")
        try tree.symlink("node_modules", to: target)
        let listing = WorktreeSeedRepository(root: tree.root).listing("")
        let entry = try #require(listing.first { $0.name == "node_modules" })
        // Not a directory, so the walk never descends through it and a link that
        // points at its own ancestor cannot make the walk loop.
        #expect(!entry.isDirectory)
        #expect(!entry.escapesRepository)
    }

    @Test func aSymlinkLoopDoesNotHangTheWalk() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let inner = try tree.directory("a/b")
        try FileManager.default.createSymbolicLink(
            atPath: inner.appendingPathComponent("up").path,
            withDestinationPath: tree.root.path
        )
        try tree.file("a/b/.env")
        let repository = WorktreeSeedRepository(root: tree.root)
        let plan = repository.planner().plan(for: WorktreeSeedFile.parse("**/.env\n"))
        #expect(plan.copies.map(\.relativePath) == ["a/b/.env"])
        #expect(!plan.reachedWalkLimit)
    }

    @Test func aSymlinkedDirectoryIsStillDeliverableWhenNamedDirectly() throws {
        let tree = try WorktreeSeedTemporaryTree()
        let target = try tree.directory("real-modules")
        try tree.symlink("node_modules", to: target)
        let repository = WorktreeSeedRepository(root: tree.root)
        let plan = repository.planner().plan(for: WorktreeSeedFile.parse("link node_modules\n"))
        #expect(plan.links.map(\.relativePath) == ["node_modules"])
    }

    @Test func aMissingDirectoryListsEmptyRatherThanFailing() throws {
        let tree = try WorktreeSeedTemporaryTree()
        #expect(WorktreeSeedRepository(root: tree.root).listing("nope").isEmpty)
    }

    @Test func aPlannerOverARealTreeFindsWhatTheFileNames() throws {
        let tree = try WorktreeSeedTemporaryTree()
        try tree.file(".worktreeinclude", ".env\nlink node_modules\nconfig/*.local.json\n")
        try tree.file(".env")
        _ = try tree.directory("node_modules")
        try tree.file("config/app.local.json")
        try tree.file("config/app.json")
        let repository = WorktreeSeedRepository(root: tree.root)
        let file = try #require(try repository.includeFile())
        let plan = repository.planner().plan(for: file)
        #expect(plan.copies.map(\.relativePath) == [".env", "config/app.local.json"])
        #expect(plan.links.map(\.relativePath) == ["node_modules"])
    }
}

@Suite("worktreeinclude applied")
struct WorktreeSeedApplierTests {
    private func plan(_ text: String, in tree: WorktreeSeedTemporaryTree, alreadyPresent: Set<String> = []) -> WorktreeSeedPlan {
        WorktreeSeedRepository(root: tree.root)
            .planner()
            .plan(for: WorktreeSeedFile.parse(text), alreadyPresent: alreadyPresent)
    }

    @Test func aCopiedFileArrivesWithItsContents() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file(".env", "TOKEN=1")
        let report = WorktreeSeedApplier().apply(
            plan(".env", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.copied == [".env"])
        #expect(report.isComplete)
        let landed = destination.root.appendingPathComponent(".env")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "TOKEN=1")
    }

    @Test func aNestedCopyCreatesItsParentDirectories() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file("config/nested/local.json", "{}")
        let report = WorktreeSeedApplier().apply(
            plan("config/nested/local.json", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.copied == ["config/nested/local.json"])
        #expect(FileManager.default.fileExists(
            atPath: destination.root.appendingPathComponent("config/nested/local.json").path
        ))
    }

    @Test func aCopiedDirectoryArrivesWholeWithoutBeingWalkedByThePlan() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file("cache/a/b.txt", "deep")
        let report = WorktreeSeedApplier().apply(
            plan("cache", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.copied == ["cache"])
        #expect(try String(
            contentsOf: destination.root.appendingPathComponent("cache/a/b.txt"),
            encoding: .utf8
        ) == "deep")
    }

    @Test func aLinkPointsAtTheOriginalByAbsolutePath() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        _ = try source.directory("node_modules")
        let report = WorktreeSeedApplier().apply(
            plan("link node_modules", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.linked == ["node_modules"])
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.root.appendingPathComponent("node_modules").path
        )
        #expect(target == source.root.standardizedFileURL.appendingPathComponent("node_modules").path)
        #expect(target.hasPrefix("/"))
    }

    @Test func aFileTheWorktreeAlreadyHasIsNotOverwritten() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file("config.json", "from the source")
        try destination.file("config.json", "from git")
        // The plan itself does not know: this is the applier's own last check,
        // for a path that appeared between planning and applying.
        let report = WorktreeSeedApplier().apply(
            plan("config.json", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.skipped == ["config.json"])
        #expect(report.copied.isEmpty)
        #expect(try String(
            contentsOf: destination.root.appendingPathComponent("config.json"),
            encoding: .utf8
        ) == "from git")
    }

    @Test func aDanglingSymlinkCountsAsOccupied() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file(".env", "TOKEN=1")
        try destination.symlink(".env", to: URL(fileURLWithPath: "/nonexistent/target"))
        let report = WorktreeSeedApplier().apply(
            plan(".env", in: source),
            from: source.root,
            to: destination.root
        )
        #expect(report.skipped == [".env"])
        #expect(report.failed.isEmpty)
    }

    @Test func aDanglingSourceSymlinkIsCopiedAsALinkNode() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try FileManager.default.createSymbolicLink(
            atPath: source.root.appendingPathComponent("local-config").path,
            withDestinationPath: "missing-config"
        )

        let seedPlan = plan("local-config", in: source)
        #expect(seedPlan.copies.map(\.relativePath) == ["local-config"])
        let report = WorktreeSeedApplier().apply(
            seedPlan,
            from: source.root,
            to: destination.root
        )

        #expect(report.copied == ["local-config"])
        #expect(report.failed.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.root.appendingPathComponent("local-config").path
        ) == "missing-config")
    }

    @Test func aDestinationSymlinkAncestorCannotRedirectACopy() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        let outside = try WorktreeSeedTemporaryTree("outside")
        try source.file("config/credentials", "secret")
        try destination.symlink("config", to: outside.root)

        let report = WorktreeSeedApplier().apply(
            plan("config/credentials", in: source),
            from: source.root,
            to: destination.root
        )

        #expect(report.copied.isEmpty)
        #expect(report.failed == [
            WorktreeSeedFailure(
                relativePath: "config/credentials",
                reason: "destination ancestor is a symlink: config"
            ),
        ])
        #expect(!FileManager.default.fileExists(
            atPath: outside.root.appendingPathComponent("credentials").path
        ))
    }

    @Test func aPathThatLeftTheRepositoryBetweenPlanAndApplyIsReportedNotCrashed() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file(".env")
        let plan = plan(".env", in: source)
        try FileManager.default.removeItem(at: source.root.appendingPathComponent(".env"))
        let report = WorktreeSeedApplier().apply(plan, from: source.root, to: destination.root)
        #expect(report.failed == [
            WorktreeSeedFailure(relativePath: ".env", reason: "no longer in the repository"),
        ])
        #expect(!report.isComplete)
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        try source.file(".env")
        try source.file("config.json")
        let plan = plan(".env\nconfig.json\n", in: source)
        try FileManager.default.removeItem(at: source.root.appendingPathComponent(".env"))
        let report = WorktreeSeedApplier().apply(plan, from: source.root, to: destination.root)
        #expect(report.copied == ["config.json"])
        #expect(report.failed.map(\.relativePath) == [".env"])
        #expect(report.deliveredCount == 1)
    }

    @Test func anEmptyPlanTouchesNothing() throws {
        let source = try WorktreeSeedTemporaryTree("source")
        let destination = try WorktreeSeedTemporaryTree("destination")
        let report = WorktreeSeedApplier().apply(
            WorktreeSeedPlan(),
            from: source.root,
            to: destination.root
        )
        #expect(report == WorktreeSeedReport())
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.root.path).isEmpty)
    }
}
