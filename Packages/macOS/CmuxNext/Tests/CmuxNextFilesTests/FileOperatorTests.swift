import Foundation
import Testing
@testable import CmuxNextFiles
import CmuxNextWakeups

/// Rename, new folder, duplicate, trash and put back, copy and move with
/// conflicts. Every write is inside a fresh temp folder.
struct FileOperatorTests {
    private let files = FileOperator(work: BackgroundWork())

    @Test func renameRefusesTakenAndInvalidNames() async throws {
        let temp = try TempFolder()
        let a = try temp.file("a.txt")
        try temp.file("b.txt")
        let renamed = try await files.rename(a, to: "c.txt")
        #expect(renamed.lastPathComponent == "c.txt")
        await #expect(throws: FileBrowserError.exists(temp.url.appendingPathComponent("b.txt"))) {
            try await files.rename(renamed, to: "b.txt")
        }
        await #expect(throws: FileBrowserError.invalidName("x/y")) { try await files.rename(renamed, to: "x/y") }
        #expect(temp.names() == ["b.txt", "c.txt"])
    }

    @Test func caseOnlyRenameWorks() async throws {
        let temp = try TempFolder()
        let a = try temp.file("readme")
        _ = try await files.rename(a, to: "README")
        #expect(temp.names() == ["README"])
    }

    @Test func newFolderAndDuplicateUseFinderNames() async throws {
        let temp = try TempFolder()
        let first = try await files.newFolder(in: temp.url, named: "untitled folder")
        let second = try await files.newFolder(in: temp.url, named: "untitled folder")
        #expect(first.lastPathComponent == "untitled folder")
        #expect(second.lastPathComponent == "untitled folder 2")
        let doc = try temp.file("doc.txt", bytes: 5)
        let copies = try await files.duplicate([doc])
        let again = try await files.duplicate([doc])
        #expect(copies.map(\.lastPathComponent) == ["doc copy.txt"])
        #expect(again.map(\.lastPathComponent) == ["doc copy 2.txt"])
        #expect(try Data(contentsOf: copies[0]).count == 5)
    }

    @Test func trashThenPutBack() async throws {
        let temp = try TempFolder()
        let doc = try temp.file("gone.txt", bytes: 3)
        let trashed = try await files.trash([doc])
        #expect(!temp.names().contains("gone.txt"))
        #expect(FileManager.default.fileExists(atPath: trashed[0].trashed.path))
        let back = try await files.putBack(trashed)
        #expect(back.map(\.lastPathComponent) == ["gone.txt"])
        #expect(temp.names() == ["gone.txt"])
    }

    @Test func copyAsksAboutConflictsAndHonorsEachChoice() async throws {
        let temp = try TempFolder()
        let source = try temp.folder("src")
        let dest = try temp.folder("dst")
        for name in ["a", "b", "c", "d"] { try temp.file(name, bytes: 10, in: "src") }
        for name in ["a", "b", "c"] { try temp.file(name, bytes: 1, in: "dst") }
        let answers = ["a": ConflictChoice.keepBoth, "b": .replace, "c": .skip]
        var placed: [URL: URL] = [:]
        var sawProgress = false
        let urls = ["a", "b", "c", "d"].map { source.appendingPathComponent($0) }
        for try await event in files.transfer(urls, to: dest, mode: .copy, resolve: { conflict in
            ConflictAnswer(answers[conflict.source.lastPathComponent] ?? .stop)
        }) {
            switch event {
            case .progress(let progress): sawProgress = sawProgress || progress.bytesTotal == 40
            case .finished(let done, let replaced):
                placed = done
                #expect(replaced.map(\.original.lastPathComponent) == ["b"])
            }
        }
        #expect(sawProgress)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dest.path))
        #expect(names == ["a", "a 2", "b", "c", "d"])
        #expect(try Data(contentsOf: dest.appendingPathComponent("b")).count == 10)
        #expect(try Data(contentsOf: dest.appendingPathComponent("c")).count == 1)
        #expect(placed.count == 3)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: source.path)) == ["a", "b", "c", "d"])
    }

    @Test func stopEndsAndApplyToAllAsksOnce() async throws {
        let temp = try TempFolder()
        let source = try temp.folder("src")
        let dest = try temp.folder("dst")
        for name in ["a", "b", "c"] { try temp.file(name, in: "src"); try temp.file(name, in: "dst") }
        let asked = AskCounter()
        let urls = ["a", "b", "c"].map { source.appendingPathComponent($0) }
        for try await _ in files.transfer(urls, to: dest, mode: .copy, resolve: { _ in
            await asked.bump()
            return ConflictAnswer(.keepBoth, applyToAll: true)
        }) {}
        #expect(await asked.count == 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dest.path)) == ["a", "a 2", "b", "b 2", "c", "c 2"])
    }

    @Test func moveOnOneVolumeRenamesAndRefusesIntoItself() async throws {
        let temp = try TempFolder()
        let folder = try temp.folder("box")
        let doc = try temp.file("doc", bytes: 4)
        for try await _ in files.transfer([doc], to: folder, mode: .move, resolve: { _ in ConflictAnswer(.stop) }) {}
        #expect(temp.names() == ["box"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("doc").path))
        await #expect(throws: (any Error).self) {
            for try await _ in files.transfer([folder], to: folder, mode: .move, resolve: { _ in ConflictAnswer(.stop) }) {}
        }
    }
}

/// Counts conflict prompts across the resolver's async calls.
private actor AskCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
