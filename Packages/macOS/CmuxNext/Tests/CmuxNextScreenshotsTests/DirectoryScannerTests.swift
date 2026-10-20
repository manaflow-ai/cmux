import CmuxNextFileGrid
import Foundation
import Testing

/// Listing folders: which files a rule lists, how deep, and the facts each item carries.
@Suite struct DirectoryScannerTests {
    @Test func listsPicturesAndMoviesOnlyAndSkipsHiddenFiles() async throws {
        let folder = try TemporaryFolder()
        try folder.write("Screenshot 1.png", bytes: 10, modified: Date(timeIntervalSince1970: 100))
        try folder.write("Recording.mov")
        try folder.write("notes.txt")
        try folder.write(".Screenshot 2.png")
        try folder.folder("subfolder")
        try folder.write("subfolder/deep.png")
        let result = await DirectoryScanner().scan(folder.url, sourceID: "s", rule: FileGridScanRule())
        #expect(result.readable)
        let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Screenshot 1.png", "Recording.mov"])
        #expect(byName["Screenshot 1.png"]?.kind == .image)
        #expect(byName["Screenshot 1.png"]?.size == 10)
        #expect(byName["Screenshot 1.png"]?.modified == Date(timeIntervalSince1970: 100))
        #expect(byName["Recording.mov"]?.kind == .video)
        #expect(result.items.allSatisfy { $0.sourceID == "s" })
    }

    /// The macOS preview folder: one level of NSIRD_screencaptureui_* folders, nothing else.
    @Test func entersOnlyPrefixedSubfoldersToTheRuleDepth() async throws {
        let folder = try TemporaryFolder()
        try folder.write("NSIRD_screencaptureui_ab12/Screenshot.png")
        try folder.write("NSIRD_screencaptureui_ab12/inner/too-deep.png")
        try folder.write("SomethingElse/other.png")
        try folder.write("top.png")
        let rule = FileGridScanRule(depth: 1, folderPrefix: "NSIRD_screencaptureui_")
        let names = await DirectoryScanner().scan(folder.url, sourceID: "s", rule: rule).items.map(\.name).sorted()
        #expect(names == ["Screenshot.png", "top.png"])
    }

    @Test func namePrefixesAndExtraExtensions() {
        let quickTime = FileGridScanRule(kinds: [.video], namePrefixes: ["Screen Recording"])
        #expect(quickTime.kind(ofFileNamed: "Screen Recording 2026-10-19.mov") == .video)
        #expect(quickTime.kind(ofFileNamed: "Holiday.mov") == nil)
        #expect(quickTime.kind(ofFileNamed: "Screen Recording.png") == nil)
        let snagit = FileGridScanRule(extraImageExtensions: ["snagx"])
        #expect(snagit.kind(ofFileNamed: "Capture.SNAGX") == .image)
        #expect(FileGridScanRule().kind(ofFileNamed: "Capture.snagx") == nil)
        #expect(FileGridScanRule(kinds: []).kind(ofFileNamed: "notes.txt") == .other)
    }

    @Test func aMissingFolderIsUnreadable() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        let result = await DirectoryScanner().scan(missing, sourceID: "s", rule: FileGridScanRule())
        #expect(!result.readable)
        #expect(result.items.isEmpty)
    }

    @Test func itemAtAPathFollowsTheRule() async throws {
        let folder = try TemporaryFolder()
        let png = try folder.write("a.png")
        let text = try folder.write("a.txt")
        let scanner = DirectoryScanner()
        #expect(await scanner.item(at: png, sourceID: "s", rule: FileGridScanRule())?.name == "a.png")
        #expect(await scanner.item(at: text, sourceID: "s", rule: FileGridScanRule()) == nil)
        try FileManager.default.removeItem(at: png)
        #expect(await scanner.item(at: png, sourceID: "s", rule: FileGridScanRule()) == nil)
    }

    /// A folder of thousands of screenshots (the user's ~/screenshots holds 3 111) lists in one pass.
    @Test func listsThreeThousandFilesQuickly() async throws {
        let folder = try TemporaryFolder()
        for index in 0..<3_000 { try folder.write("Screenshot \(index).png", bytes: 1) }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = await clock.measure {
            count = await DirectoryScanner().scan(folder.url, sourceID: "s", rule: FileGridScanRule()).items.count
        }
        #expect(count == 3_000)
        #expect(elapsed < .seconds(3), "listing 3 000 files took \(elapsed)")
    }
}
