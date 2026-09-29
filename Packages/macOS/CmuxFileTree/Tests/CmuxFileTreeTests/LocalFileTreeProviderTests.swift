import Darwin
import Foundation
import Testing
@testable import CmuxFileTree

@Suite struct LocalFileTreeProviderTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listsKindsSizesAndHiddenFlags() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent(".env"))
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-dir").path, withDestinationPath: "src")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-file").path, withDestinationPath: "a.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        let flagged = root.appendingPathComponent("flagged")
        try Data().write(to: flagged)
        #expect(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)

        let listing = try await LocalFileTreeProvider().listDirectory(at: root.path)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a.txt", ".env", "src", "link-dir", "link-file", "dangling", "flagged"])
        #expect(byName["a.txt"]?.kind == .file)
        #expect(byName["a.txt"]?.size == 5)
        #expect(byName["a.txt"]?.path == root.path + "/a.txt")
        #expect(byName["a.txt"]?.modificationTime != nil)
        #expect(byName["src"]?.kind == .directory)
        #expect(byName["link-dir"]?.kind == .symbolicLinkToDirectory)
        #expect(byName["link-dir"]?.isDirectory == true)
        #expect(byName["link-file"]?.kind == .symbolicLink)
        #expect(byName["dangling"]?.kind == .symbolicLink)
        #expect(byName[".env"]?.isHidden == true)
        #expect(byName["flagged"]?.isHidden == true)
        #expect(byName["a.txt"]?.isHidden == false)
    }

    @Test func listsUnicodeNamesByteForByte() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "caf\u{00E9} \u{65E5}\u{672C}.md"
        try Data().write(to: root.appendingPathComponent(name))
        let listing = try await LocalFileTreeProvider().listDirectory(at: root.path)
        #expect(listing.entries.count == 1)
        #expect(listing.entries.first?.name.precomposedStringWithCanonicalMapping == name)
    }

    @Test func missingDirectoryThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await LocalFileTreeProvider().listDirectory(at: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func fsEventsReportTheChangedDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: false)
        let provider = LocalFileTreeProvider(eventLatency: 0.05)
        let stream = try #require(provider.changes(under: root.path))
        let target = root.path + "/src"
        let observed = Task { () -> Bool in
            for await batch in stream where batch.directories.contains(target) || batch.subtrees.contains(target) {
                return true
            }
            return false
        }
        // FSEvents needs the stream running before the write it should see;
        // write repeatedly until the event arrives or the deadline passes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let writer = Task {
            var counter = 0
            while !Task.isCancelled && ContinuousClock.now < deadline {
                counter += 1
                try? Data().write(to: root.appendingPathComponent("src/file\(counter)"))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let timeout = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            observed.cancel()
        }
        let sawEvent = await observed.value
        writer.cancel()
        timeout.cancel()
        #expect(sawEvent)
    }
}
