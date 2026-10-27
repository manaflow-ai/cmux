#if !canImport(Darwin)
@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The Linux side of Keep in Sync (p15-oracle-139): ``HistoryInotifyEvent`` reads the kernel's
/// `struct inotify_event` records and says which of them ``HistoryFileWatch`` reports, and the watch itself
/// calls back on a write next to the database.
struct HistoryFileWatchInotifyTests {
    private let names: Set<String> = ["History", "History-wal", "History-journal"]

    /// One record as the kernel writes it, in host byte order: wd, mask, cookie, len, then `len` name bytes.
    /// A name gets its NUL and, with `paddedTo`, more NULs up to that length; an empty name has no bytes.
    private func record(mask: some BinaryInteger, name: String = "", paddedTo: Int? = nil) -> [UInt8] {
        var nameBytes: [UInt8] = name.isEmpty ? [] : Array(name.utf8) + [0]
        if let paddedTo { nameBytes += [UInt8](repeating: 0, count: paddedTo - nameBytes.count) }
        return word(7) + word(UInt32(truncatingIfNeeded: mask)) + word(0) + word(UInt32(nameBytes.count)) + nameBytes
    }

    /// `value`'s bytes in host order.
    private func word(_ value: UInt32) -> [UInt8] {
        let host = value.littleEndian
        return (0..<4).map { UInt8(truncatingIfNeeded: host >> (8 * $0)) }
    }

    // MARK: parse

    @Test func parseReadsANameItsNULEnds() {
        let events = HistoryInotifyEvent.parse(record(mask: IN_MODIFY, name: "History")[...])
        #expect(events == [HistoryInotifyEvent(mask: UInt32(IN_MODIFY), name: "History")])
    }

    @Test func parseReadsANULPaddedName() {
        let events = HistoryInotifyEvent.parse(record(mask: IN_CLOSE_WRITE, name: "History-wal", paddedTo: 16)[...])
        #expect(events == [HistoryInotifyEvent(mask: UInt32(IN_CLOSE_WRITE), name: "History-wal")])
    }

    @Test func parseReadsARecordWithNoName() {
        let events = HistoryInotifyEvent.parse(record(mask: IN_DELETE_SELF)[...])
        #expect(events == [HistoryInotifyEvent(mask: UInt32(IN_DELETE_SELF), name: "")])
    }

    @Test func parseReadsRecordsBackToBack() {
        let bytes = record(mask: IN_CREATE, name: "History-journal", paddedTo: 32) + record(mask: IN_Q_OVERFLOW)
            + record(mask: IN_MOVED_TO, name: "Cookies", paddedTo: 16)
        #expect(HistoryInotifyEvent.parse(bytes[...]) == [
            HistoryInotifyEvent(mask: UInt32(IN_CREATE), name: "History-journal"),
            HistoryInotifyEvent(mask: UInt32(IN_Q_OVERFLOW), name: ""),
            HistoryInotifyEvent(mask: UInt32(IN_MOVED_TO), name: "Cookies"),
        ])
    }

    @Test func parseStopsAtARecordCutOffAtTheEnd() {
        let first = record(mask: IN_MODIFY, name: "History", paddedTo: 16)
        let second = record(mask: IN_DELETE, name: "History-wal", paddedTo: 16)
        let expected = [HistoryInotifyEvent(mask: UInt32(IN_MODIFY), name: "History")]
        // The second record's name runs past the bytes.
        #expect(HistoryInotifyEvent.parse((first + second.dropLast(3))[...]) == expected)
        // Only part of the second record's header is there.
        #expect(HistoryInotifyEvent.parse((first + second.prefix(10))[...]) == expected)
        #expect(HistoryInotifyEvent.parse(ArraySlice<UInt8>()).isEmpty)
    }

    @Test func parseReadsASliceThatDoesNotStartAtZero() {
        let bytes = [0xAA, 0xBB, 0xCC] + record(mask: IN_MODIFY, name: "History")
        #expect(HistoryInotifyEvent.parse(bytes[3...]) == [HistoryInotifyEvent(mask: UInt32(IN_MODIFY), name: "History")])
    }

    // MARK: concerns

    @Test func concernsTheDatabaseItsWALAndItsJournal() {
        for name in ["History", "History-wal", "History-journal"] {
            #expect(HistoryInotifyEvent(mask: UInt32(IN_MODIFY), name: name).concerns(names))
        }
    }

    @Test func doesNotConcernOtherFilesInTheFolder() {
        for name in ["Cookies", "History-shm", "Preferences", "history", ""] {
            #expect(!HistoryInotifyEvent(mask: UInt32(IN_MODIFY), name: name).concerns(names))
        }
    }

    @Test func concernsAnOverflowAndTheFolderGoing() {
        for mask in [IN_Q_OVERFLOW, IN_DELETE_SELF, IN_MOVE_SELF] {
            #expect(HistoryInotifyEvent(mask: UInt32(mask), name: "").concerns(names))
        }
    }

    // MARK: HistoryFileWatch

    @Test(.timeLimit(.minutes(1))) func theWatchReportsAWALMadeAfterItStarted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "history-watch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "History")
        try Data("one".utf8).write(to: file)
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        let watch = HistoryFileWatch(file: file, scope: nil) { _ = continuation.yield() }
        defer { watch.cancel() }

        try Data("two".utf8).write(to: folder.appending(path: "History-wal"))

        var reported = false
        for await _ in changes {
            reported = true
            break
        }
        #expect(reported)
    }
}

/// ``FolderBookmark`` on Linux keeps the picked folder's absolute path.
struct FolderBookmarkLinuxTests {
    @Test func aBookmarkResolvesToItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "bookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bookmark = try #require(FolderBookmark.make(folder))
        let resolved = try #require(FolderBookmark.resolve(bookmark))
        #expect(resolved.path == folder.standardizedFileURL.path)
        #expect(resolved.hasDirectoryPath)
    }

    @Test func makeRefusesAURLThatIsNotAFile() throws {
        let page = try #require(URL(string: "https://example.com/profile"))
        #expect(FolderBookmark.make(page) == nil)
    }

    @Test func resolveRefusesARelativePathAndBytesThatAreNotUTF8() {
        #expect(FolderBookmark.resolve(Data("Library/Safari".utf8)) == nil)
        #expect(FolderBookmark.resolve(Data()) == nil)
        #expect(FolderBookmark.resolve(Data([0xFF, 0xFE, 0x2F])) == nil)
    }

    @Test func thereIsNoScopeToTake() {
        #expect(!FolderBookmark.startAccessing(URL(fileURLWithPath: "/tmp", isDirectory: true)))
    }
}
#endif
