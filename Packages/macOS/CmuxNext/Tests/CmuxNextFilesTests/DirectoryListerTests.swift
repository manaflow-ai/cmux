import Foundation
import Testing
@testable import CmuxNextFiles

/// The `getattrlistbulk` lister against real items in a temp folder.
struct DirectoryListerTests {
    @Test func listsKindsSizesAndHiddenItems() async throws {
        let temp = try TempFolder()
        try temp.file("plain.txt", bytes: 42)
        try temp.file(".dotfile")
        try temp.folder("Sub")
        try temp.folder("Thing.app")
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"),
                                                   withDestinationURL: temp.url.appendingPathComponent("Sub"))
        let flagged = try temp.file("flagged")
        #expect(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)

        let entries = try await DirectoryLister().list(temp.url)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["plain.txt", ".dotfile", "Sub", "Thing.app", "link", "flagged"])
        #expect(byName["plain.txt"]?.kind == .file)
        #expect(byName["plain.txt"]?.size == 42)
        #expect(byName["plain.txt"]?.isHidden == false)
        #expect(byName[".dotfile"]?.isHidden == true)
        #expect(byName["flagged"]?.isHidden == true)
        #expect(byName["Sub"]?.kind == .folder)
        #expect(byName["Sub"]?.size == 0)
        #expect(byName["Thing.app"]?.kind == .package)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName["plain.txt"]?.url.path == temp.url.appendingPathComponent("plain.txt").path)
        #expect(abs((byName["plain.txt"]?.modified.timeIntervalSinceNow ?? 999)) < 120)
    }

    @Test func singleEntryMatchesTheListingAndNilWhenGone() async throws {
        let temp = try TempFolder()
        let file = try temp.file("one.txt", bytes: 7)
        let entry = await DirectoryLister().entry(at: file)
        #expect(entry?.size == 7)
        #expect(entry?.kind == .file)
        try FileManager.default.removeItem(at: file)
        #expect(await DirectoryLister().entry(at: file) == nil)
    }

    @Test func unreadableFolderThrows() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await #expect(throws: FileBrowserError.self) { try await DirectoryLister().list(missing) }
    }

    @Test func listsTenThousandItems() async throws {
        let temp = try TempFolder()
        for index in 1...10_000 { FileManager.default.createFile(atPath: temp.url.appendingPathComponent("f\(index)").path, contents: nil) }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = try await clock.measure { count = try await DirectoryLister().list(temp.url).count }
        #expect(count == 10_000)
        // Finder's own `count items` takes 350-860 ms on this folder size (PARITY.md).
        #expect(elapsed < .milliseconds(500))
    }
}
