import CmuxNextFileGrid
import CmuxNextFiles
import CmuxNextScreenshots
import Foundation
import Testing

/// Reading a source's folders through CmuxNextFiles: which files a rule lists, how deep, the
/// facts each item carries, and the folders a watch must cover.
@Suite struct ScreenshotFolderReaderTests {
    static func source(_ folder: URL, rule: ScreenshotScanRule = ScreenshotScanRule()) -> ScreenshotSource {
        ScreenshotSource(id: "s", label: "s", folder: folder, origin: .custom, rule: rule)
    }

    @Test func listsPicturesAndMoviesOnlyAndSkipsHiddenFiles() async throws {
        let folder = try TemporaryFolder()
        try folder.write("Screenshot 1.png", bytes: 10, modified: Date(timeIntervalSince1970: 100))
        try folder.write("Recording.mov")
        try folder.write("notes.txt")
        try folder.write(".Screenshot 2.png")
        try folder.write("subfolder/deep.png")
        let result = await ScreenshotFolderReader().read(Self.source(folder.url))
        #expect(result.readable)
        #expect(result.folders == [folder.url.path])
        let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Screenshot 1.png", "Recording.mov"])
        #expect(byName["Screenshot 1.png"]?.kind == .image)
        #expect(byName["Screenshot 1.png"]?.size == 10)
        #expect(byName["Screenshot 1.png"]?.modified == Date(timeIntervalSince1970: 100))
        #expect(byName["Recording.mov"]?.kind == .video)
        #expect(result.items.allSatisfy { $0.sourceID == "s" })
    }

    /// The macOS preview folder: one level of NSIRD_screencaptureui_* folders, each watched too.
    @Test func entersOnlyPrefixedSubfoldersToTheRuleDepthAndReportsThem() async throws {
        let folder = try TemporaryFolder()
        try folder.write("NSIRD_screencaptureui_ab12/Screenshot.png")
        try folder.write("NSIRD_screencaptureui_ab12/inner/too-deep.png")
        try folder.write("SomethingElse/other.png")
        try folder.write("top.png")
        let rule = ScreenshotScanRule(depth: 1, folderPrefix: "NSIRD_screencaptureui_")
        let result = await ScreenshotFolderReader().read(Self.source(folder.url, rule: rule))
        #expect(result.items.map(\.name).sorted() == ["Screenshot.png", "top.png"])
        #expect(Set(result.folders) == [folder.url.path, folder.url.appendingPathComponent("NSIRD_screencaptureui_ab12").path])
    }

    @Test func namePrefixesAndExtraExtensions() {
        let quickTime = ScreenshotScanRule(kinds: [.video], namePrefixes: ["Screen Recording"])
        #expect(quickTime.kind(ofFileNamed: "Screen Recording 2026-10-19.mov") == .video)
        #expect(quickTime.kind(ofFileNamed: "Holiday.mov") == nil)
        #expect(quickTime.kind(ofFileNamed: "Screen Recording.png") == nil)
        let snagit = ScreenshotScanRule(extraImageExtensions: ["snagx"])
        #expect(snagit.kind(ofFileNamed: "Capture.SNAGX") == .image)
        #expect(ScreenshotScanRule().kind(ofFileNamed: "Capture.snagx") == nil)
        #expect(ScreenshotScanRule(kinds: []).kind(ofFileNamed: "notes.txt") == .other)
    }

    @Test func aMissingFolderIsUnreadable() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        let result = await ScreenshotFolderReader().read(Self.source(missing))
        #expect(!result.readable)
        #expect(result.items.isEmpty)
    }

    /// One changed path is one `lstat` through the lister: a deleted file reads as gone.
    @Test func itemAtAPathFollowsTheRuleAndSeesADeletion() async throws {
        let folder = try TemporaryFolder()
        let png = try folder.write("a.png")
        let text = try folder.write("a.txt")
        let reader = ScreenshotFolderReader()
        let source = Self.source(folder.url)
        #expect(await reader.item(at: png, in: source)?.name == "a.png")
        #expect(await reader.item(at: text, in: source) == nil)
        try FileManager.default.removeItem(at: png)
        #expect(await reader.item(at: png, in: source) == nil)
    }

    /// The reader lists through any `DirectoryListing`: the Files pane's seam.
    @Test func readsThroughTheFilesListingSeam() async {
        let root = URL(fileURLWithPath: "/fake", isDirectory: true)
        let lister = FixedLister(entries: [
            root.path: [FileEntry(name: "a.png", in: root, kind: .file, size: 3), FileEntry(name: "b.mov", in: root, kind: .file)],
        ])
        let result = await ScreenshotFolderReader(lister: lister).read(Self.source(root))
        #expect(result.items.map(\.name).sorted() == ["a.png", "b.mov"])
    }

    /// A folder of thousands of screenshots (the user's ~/screenshots holds 3 111) lists in one pass.
    @Test func listsThreeThousandFilesQuickly() async throws {
        let folder = try TemporaryFolder()
        for index in 0..<3_000 { try folder.write("Screenshot \(index).png", bytes: 1) }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = await clock.measure {
            count = await ScreenshotFolderReader().read(Self.source(folder.url)).items.count
        }
        #expect(count == 3_000)
        #expect(elapsed < .seconds(3), "listing 3 000 files took \(elapsed)")
    }
}

/// Fixed listings by folder path.
nonisolated struct FixedLister: DirectoryListing {
    var entries: [String: [FileEntry]]
    func list(_ folder: URL) async throws -> [FileEntry] {
        guard let found = entries[folder.path] else { throw FileBrowserError.unreadable(folder, ENOENT) }
        return found
    }
    func entry(at url: URL) async -> FileEntry? {
        entries[url.deletingLastPathComponent().path]?.first { $0.name == url.lastPathComponent }
    }
}
