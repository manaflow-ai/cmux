import XCTest

@testable import CmuxCommandPalette

// MARK: - Quick Open File Search

final class CommandPaletteQuickOpenFileSearchTests: XCTestCase {

    // MARK: commandPaletteFileSearchResolve

    func testResolveEmptyQueryReturnsWorkspaceRoot() {
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, root)
        XCTAssertEqual(searchTerm, "")
        XCTAssertTrue(isPathMode)
    }

    func testResolveWhitespaceOnlyReturnsWorkspaceRoot() {
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "   ",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, root)
        XCTAssertEqual(searchTerm, "")
        XCTAssertTrue(isPathMode)
    }

    func testResolveHomePrefix() {
        let home = NSHomeDirectory()
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "~",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, home)
        XCTAssertEqual(searchTerm, "")
        XCTAssertTrue(isPathMode)
    }

    func testResolveHomeSubdirectory() {
        let home = NSHomeDirectory()
        let root = "/Users/test/Projects/MyApp"
        let (dir, _, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "~/Develop",
            workspaceRoot: root
        )
        // ~/Develop may or may not exist — if it does, dir should be it;
        // if not, dir falls back to the longest existing prefix (likely home).
        XCTAssertTrue(dir.hasPrefix(home))
        XCTAssertTrue(isPathMode)
    }

    func testResolveRootSlash() {
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "/",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, "/")
        XCTAssertEqual(searchTerm, "")
        XCTAssertTrue(isPathMode)
    }

    func testResolveCrossDirectoryMode() {
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "main.swift",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, root)
        XCTAssertEqual(searchTerm, "main.swift")
        XCTAssertFalse(isPathMode)
    }

    func testResolveCrossDirectoryModeMultipleWords() {
        let root = "/Users/test/Projects/MyApp"
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "content view",
            workspaceRoot: root
        )
        XCTAssertEqual(dir, root)
        XCTAssertEqual(searchTerm, "content view")
        XCTAssertFalse(isPathMode)
    }

    func testResolveNilWorkspaceRootFallsBackToHome() {
        let home = NSHomeDirectory()
        let (dir, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "",
            workspaceRoot: nil
        )
        XCTAssertEqual(dir, home)
        XCTAssertEqual(searchTerm, "")
        XCTAssertTrue(isPathMode)
    }

    // MARK: resolveLongestExistingDirectory

    func testResolveExistingRootDirectory() {
        let (dir, remainder) = CommandPaletteQuickOpenFileSearch.resolveLongestExistingDirectory("/")
        XCTAssertEqual(dir, "/")
        XCTAssertEqual(remainder, "")
    }

    func testResolveExistingHomeDirectory() {
        let home = NSHomeDirectory()
        let (dir, remainder) = CommandPaletteQuickOpenFileSearch.resolveLongestExistingDirectory(home)
        XCTAssertEqual(dir, home)
        XCTAssertEqual(remainder, "")
    }

    func testResolveExistingDirectoryWithRemainder() {
        let home = NSHomeDirectory()
        let (dir, remainder) = CommandPaletteQuickOpenFileSearch.resolveLongestExistingDirectory(home + "/nonexistent_subdir_xyz")
        XCTAssertEqual(dir, home)
        XCTAssertEqual(remainder, "nonexistent_subdir_xyz")
    }

    func testResolveCompletelyNonexistentPath() {
        // "/xyz_nonexistent_root" doesn't exist, but "/" does —
        // so dir falls back to "/" with the rest as remainder.
        let (dir, remainder) = CommandPaletteQuickOpenFileSearch.resolveLongestExistingDirectory("/xyz_nonexistent_root/foo/bar")
        XCTAssertEqual(dir, "/")
        XCTAssertFalse(remainder.isEmpty)
    }

    // MARK: commandPaletteFileSearchPathForDirectory

    func testPathForHomeSubdirectory() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home + "/Develop", isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(url, rootDir: "/tmp/workspace")
        XCTAssertEqual(result, "~/Develop/")
    }

    func testPathForHomeDirectoryItself() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home, isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(url, rootDir: "/tmp/workspace")
        XCTAssertEqual(result, "~/")
    }

    func testPathUnderWorkspaceRoot() {
        let root = "/Users/test/Projects/MyApp"
        let url = URL(fileURLWithPath: root + "/Sources", isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(url, rootDir: root)
        XCTAssertEqual(result, "./Sources/")
    }

    func testPathUnderWorkspaceRootCanOmitPathModePrefix() {
        let root = "/Users/test/Projects/MyApp"
        let url = URL(fileURLWithPath: root + "/Sources", isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(
            url,
            rootDir: root,
            usePathPrefix: false
        )

        XCTAssertEqual(result, "Sources/")

        let (_, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: result,
            workspaceRoot: root
        )
        XCTAssertEqual(searchTerm, "Sources/")
        XCTAssertFalse(isPathMode)
    }

    func testPathUnderWorkspaceInsideHome() {
        let root = NSHomeDirectory() + "/Develop/MyProject"
        let url = URL(fileURLWithPath: root + "/Sources", isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(url, rootDir: root)
        XCTAssertEqual(result, "./Sources/")
    }

    func testPathOutsideWorkspaceAndHome() {
        let url = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        let result = CommandPaletteQuickOpenFileSearch.pathForDirectory(url, rootDir: "/tmp/workspace")
        XCTAssertEqual(result, "/opt/homebrew/")
    }

    // MARK: commandPaletteFileSearchMatchingTerm

    func testMatchingTermEmpty() {
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm(""), "")
    }

    func testMatchingTermCrossDirectory() {
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("main.swift"), "main.swift")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("content view"), "content view")
    }

    func testCrossDirectorySlashQueryMatchesRelativePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-slash-\(UUID().uuidString)", isDirectory: true)
        let crypto = root.appendingPathComponent("crypto", isDirectory: true)
        try FileManager.default.createDirectory(at: crypto, withIntermediateDirectories: true)
        let file = crypto.appendingPathComponent("gnupg.md")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "cry/gnu",
            rootDir: root.path
        )

        let expectedPath = file.resolvingSymlinksInPath().path
        XCTAssertTrue(
            results.contains { $0.url.resolvingSymlinksInPath().path == expectedPath },
            "Expected cry/gnu to match crypto/gnupg.md, got \(results.map { $0.url.path })"
        )
    }

    func testCrossDirectoryDirectoryQueryIncludesSelectedTopLevelDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-selected-dir-\(UUID().uuidString)", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try "swift".write(
            to: selectedDirectory.appendingPathComponent("ContentView.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "Sources/",
            rootDir: root.path
        )

        let selectedPath = selectedDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(
            results.contains { $0.url.resolvingSymlinksInPath().path == selectedPath },
            "Expected selected directory in results, got \(results.map { $0.url.path })"
        )
    }

    func testCrossDirectoryDirectoryQueryIncludesSelectedNestedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-selected-nested-dir-\(UUID().uuidString)", isDirectory: true)
        let selectedDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("CommandPalette", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try "swift".write(
            to: selectedDirectory.appendingPathComponent("QuickOpen.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "Sources/CommandPalette/",
            rootDir: root.path
        )

        let selectedPath = selectedDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(
            results.contains { $0.url.resolvingSymlinksInPath().path == selectedPath },
            "Expected selected nested directory in results, got \(results.map { $0.url.path })"
        )
    }

    func testFileSearchCrossDirectoryFuzzyMatchKeepsSlashInQuery() {
        let match = CommandPaletteQuickOpenFileSearch.fuzzyMatch(
            query: "cry/gnu",
            candidate: "crypto/gnupg.md"
        )
        XCTAssertNotNil(match)
        XCTAssertFalse(match?.indices.isEmpty ?? true)

        XCTAssertNil(
            CommandPaletteQuickOpenFileSearch.fuzzyScore(
                query: "cry/to",
                candidate: "crypto/gnupg.md"
            )
        )
    }

    func testCrossDirectorySlashQueryDoesNotMatchInsideSinglePathComponent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-slash-no-component-\(UUID().uuidString)", isDirectory: true)
        let crypto = root.appendingPathComponent("crypto", isDirectory: true)
        try FileManager.default.createDirectory(at: crypto, withIntermediateDirectories: true)
        let file = crypto.appendingPathComponent("gnupg.md")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "cry/to",
            rootDir: root.path
        )

        let unexpectedPath = file.resolvingSymlinksInPath().path
        XCTAssertFalse(
            results.contains { $0.url.resolvingSymlinksInPath().path == unexpectedPath },
            "Expected cry/to not to match crypto/gnupg.md, got \(results.map { $0.url.path })"
        )
    }

    func testSearchCrossDirectoryDeduplicatesSymlinkDirectoryCycles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-symlink-cycle-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let file = realDirectory.appendingPathComponent("needle.txt")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: realDirectory.appendingPathComponent("loop", isDirectory: true),
            withDestinationURL: root
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "needle",
            rootDir: root.path
        )

        let resolvedNeedlePath = file.resolvingSymlinksInPath().path
        let matchingNeedles = results.filter {
            $0.url.resolvingSymlinksInPath().path == resolvedNeedlePath
        }
        XCTAssertEqual(matchingNeedles.count, 1, "Expected one real needle result, got \(results.map { $0.url.path })")
    }

    func testQuickOpenRelativePathUsesWorkspaceRoot() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-quick-open-relative-\(UUID().uuidString)", isDirectory: true)
        let file = root
            .appendingPathComponent("crypto", isDirectory: true)
            .appendingPathComponent("gnupg.md")

        XCTAssertEqual(
            CommandPaletteQuickOpenFileSearch.relativePath(url: file, rootDir: root.path),
            "crypto/gnupg.md"
        )
    }

    func testMatchingTermPathOnly() {
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/"), "")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("~"), "")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./"), "")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./Sources/"), "")
    }

    func testMatchingTermNoPrefixIsCrossDirectory() {
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("main.swift"), "main.swift")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("ab"), "ab")
        // "Sources/" has no path prefix → cross-directory, full term kept
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("Sources/"), "Sources/")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("Sources/Cont"), "Sources/Cont")
    }

    func testMatchingTermPathWithSearch() {
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/b"), "b")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/Users/cha"), "cha")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("~/foo/bar/baz"), "baz")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./Sources/Cont"), "Cont")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./aaa/bbbb/"), "")
    }

    func testMatchingTermDotSlashUsesWorkspaceRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-workspace-root-\(UUID().uuidString)", isDirectory: true)
        let workspaceOnlyDirectory = root.appendingPathComponent("WorkspaceOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceOnlyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            CommandPaletteQuickOpenFileSearch.matchingTerm(
                "./WorkspaceOnly",
                workspaceRoot: root.path
            ),
            ""
        )
    }

    func testMatchingTermDirectoryWithoutTrailingSlash() {
        // /tmp always exists → browse mode (empty term).
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/tmp"), "")
        // /tmp/nonexistent_xyz doesn't exist → search term is the filename.
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/tmp/nonexistent_xyz"), "nonexistent_xyz")
    }

    func testMatchingTermDotfileSearch() throws {
        // "/.t" → search for dotfiles matching "t" in root
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/.t"), ".t")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("/.bash"), ".bash")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-dotfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousDirectory) }

        let dotTestDirectory = root.appendingPathComponent(".test", isDirectory: true)
        let dotGitPath = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: dotTestDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotGitPath, withIntermediateDirectories: true)

        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./.test"), "")
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./.git"), "")

        try FileManager.default.removeItem(at: dotGitPath)
        try "gitdir: ../.git/worktrees/example\n".write(to: dotGitPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("./.git"), ".git")

        // "~/.t" → dotfile search in home
        XCTAssertEqual(CommandPaletteQuickOpenFileSearch.matchingTerm("~/.t"), ".t")
    }

    // MARK: resolve with ./ prefix

    func testResolveDotSlashEntersPathMode() {
        let home = NSHomeDirectory()
        let (_, _, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "./Sources/",
            workspaceRoot: home
        )
        XCTAssertTrue(isPathMode)
    }

    func testResolveDotSlashWithSearch() {
        let home = NSHomeDirectory()
        let (_, _, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "./Sources/Cont",
            workspaceRoot: home
        )
        XCTAssertTrue(isPathMode)
    }

    func testResolveNoPrefixIsCrossDirectory() {
        let root = "/Users/test/Projects/MyApp"
        let (_, _, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "ab",
            workspaceRoot: root
        )
        XCTAssertFalse(isPathMode)
    }

    // MARK: shouldSkipDirectoryForQuickOpen

    func testKnownSkipDirectories() {
        let skips: [String] = [
            "node_modules", ".build", "DerivedData",
            ".svn", ".hg", "__pycache__", ".cache",
            "Pods", "Carthage", "build", "dist", "target",
            ".vscode", ".idea", "vendor",
        ]
        for name in skips {
            XCTAssertTrue(
                CommandPaletteQuickOpenFileSearch.shouldSkipDirectory(name),
                "\(name) should be skipped"
            )
        }
    }

    func testNormalDirectoriesNotSkipped() {
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory("Sources"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory("src"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory(".git"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory(".test"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory("lib"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory("MyApp"))
        XCTAssertFalse(CommandPaletteQuickOpenFileSearch.shouldSkipDirectory("Tests"))
    }
}
