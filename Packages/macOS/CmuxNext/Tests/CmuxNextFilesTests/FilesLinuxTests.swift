#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import CmuxNextFiles

/// The Linux halves of the Files seams: the inotify record reader, the freedesktop.org trash and
/// the copy without copyfile(3).
struct FilesLinuxTests {
    /// One `struct inotify_event` as the kernel writes it: wd, mask, cookie, len, then the NUL-padded name.
    private static func event(mask: Int32, name: String = "", padTo: Int = 16) -> [UInt8] {
        // SAFETY: the bytes are `value`'s own, a local copy, lent for the call.
        func word(_ value: UInt32) -> [UInt8] { unsafe withUnsafeBytes(of: value) { unsafe Array($0) } }
        var text = name.isEmpty ? [] : Array(name.utf8) + [0]
        while !text.isEmpty, text.count % padTo != 0 { text.append(0) }
        return word(1) + word(UInt32(mask)) + word(0) + word(UInt32(text.count)) + text
    }

    @Test func inotifyRecordsGiveChildNames() {
        let bytes = Self.event(mask: IN_CREATE, name: "made-1") + Self.event(mask: IN_MODIFY, name: "notes.txt")
            + Self.event(mask: IN_MOVED_TO, name: "é")
        let batch = FolderWatchStream.parse(bytes, count: bytes.count)
        #expect(batch.names == ["made-1", "notes.txt", "é"])
        #expect(!batch.rescan)
    }

    @Test func overflowAndTheFolderGoingAwayAskForARescan() {
        for mask in [IN_Q_OVERFLOW, IN_DELETE_SELF, IN_MOVE_SELF, IN_IGNORED, IN_UNMOUNT] {
            let bytes = Self.event(mask: IN_CREATE, name: "a") + Self.event(mask: mask)
            let batch = FolderWatchStream.parse(bytes, count: bytes.count)
            #expect(batch.names == ["a"])
            #expect(batch.rescan)
        }
    }

    /// A record whose name runs past the read ends the batch as a rescan; nothing past it is read.
    @Test func aCutRecordIsARescan() {
        let whole = Self.event(mask: IN_CREATE, name: "kept")
        let bytes = whole + Self.event(mask: IN_CREATE, name: "cut")
        let batch = FolderWatchStream.parse(bytes, count: whole.count + 20)
        #expect(batch.names == ["kept"])
        #expect(batch.rescan)
        #expect(FolderWatchStream.parse(bytes, count: 7).rescan)
    }

    @Test func trashWritesARecordAndPutBackRemovesIt() async throws {
        let temp = try TempFolder()
        let trash = try temp.folder("Trash")
        let doc = try temp.file("gone file.txt", bytes: 3)
        let first = try FileOperator.systemTrash(doc, namer: FileNamer(), in: trash)
        #expect(first.path == trash.path + "/files/gone file.txt")
        let record = try String(contentsOf: trash.appendingPathComponent("info/gone file.txt.trashinfo"), encoding: .utf8)
        let lines = record.split(separator: "\n").map(String.init)
        #expect(lines.first == "[Trash Info]")
        #expect(lines.contains("Path=" + temp.url.path.replacingOccurrences(of: " ", with: "%20") + "/gone%20file.txt"))
        let date = try #require(lines.first { $0.hasPrefix("DeletionDate=") })
        #expect(date.count == "DeletionDate=".count + 19)

        // A second item of the same name takes a free one, in files and info both.
        let again = try temp.file("gone file.txt", bytes: 1)
        let second = try FileOperator.systemTrash(again, namer: FileNamer(), in: trash)
        #expect(second.lastPathComponent != "gone file.txt")
        #expect(FileManager.default.fileExists(atPath: trash.path + "/info/" + second.lastPathComponent + ".trashinfo"))

        FileOperator.forgetTrashed(first)
        #expect(!FileManager.default.fileExists(atPath: trash.path + "/info/gone file.txt.trashinfo"))
    }

    @Test func trashDateIsLocalTimeWithoutAZone() throws {
        let parts = DateComponents(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7)
        let date = try #require(Calendar.current.date(from: parts))
        #expect(FileOperator.trashDate(date) == "2026-03-04T05:06:07")
    }

    @Test func copyKeepsModesTimesAndLinksAndRefusesAnExistingTarget() throws {
        let temp = try TempFolder()
        let source = try temp.folder("src")
        let script = try temp.file("run.sh", bytes: 3_000_000, in: "src")
        // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
        #expect(unsafe chmod(script.path, 0o751) == 0)
        try FileManager.default.createSymbolicLink(atPath: source.path + "/link", withDestinationPath: "run.sh")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: script.path)
        var reports: [Int64] = []
        let target = temp.url.appendingPathComponent("dst")
        try FileOperator.copy(source, to: target) { reports.append($0); return true }
        let copied = target.appendingPathComponent("run.sh")
        #expect(try Data(contentsOf: copied).count == 3_000_000)
        #expect(reports.last == 3_000_000)
        #expect(reports == reports.sorted())
        let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o751)
        #expect(attributes[.modificationDate] as? Date == old)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path + "/link") == "run.sh")
        #expect(throws: FileBrowserError.self) { try FileOperator.copy(script, to: copied) { _ in true } }
        #expect(throws: FileBrowserError.cancelled) { try FileOperator.copy(script, to: target.appendingPathComponent("stop")) { _ in false } }
    }
}
#endif
