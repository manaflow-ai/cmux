import Foundation
import Testing
@testable import CmuxNextMobile

/// The phone listener's transport journal holds session ids, so it lives in a
/// directory only this user can reach (the per-user temporary directory), never
/// in the shared /tmp, where another user could plant a link in its place or
/// read it.
struct MobileIrxJournalPathTests {
    @Test func theJournalIsInThePerUserTemporaryDirectory() {
        let temporary = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T", isDirectory: true)
        let file = MobileIrxHost.journalFile(tag: "chrome-parity", temporaryDirectory: temporary)
        #expect(file.path == "/private/var/folders/ab/xyz/T/cmux-next-irx/irx-journal-chrome-parity.jsonl")
        #expect(!file.path.hasPrefix("/tmp/"))
    }

    @Test func aTagCannotLeaveTheJournalDirectory() {
        let temporary = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T", isDirectory: true)
        let file = MobileIrxHost.journalFile(tag: "../../../tmp/x y", temporaryDirectory: temporary)
        #expect(file.deletingLastPathComponent().path == "/private/var/folders/ab/xyz/T/cmux-next-irx")
        #expect(!file.lastPathComponent.contains("/"))
        #expect(!file.lastPathComponent.contains(".."))
    }

    /// The journal earlier builds left in the shared /tmp (readable by every
    /// user) is removed; a link there is never followed or removed.
    @Test func theOldSharedJournalIsRemovedButNotThroughALink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("irx-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("cmux-next-irx-journal-t1.jsonl")
        try Data("session".utf8).write(to: old)
        MobileIrxHost.removeSharedJournal(tag: "t1", directory: dir.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))

        let target = dir.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let link = dir.appendingPathComponent("cmux-next-irx-journal-t2.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        MobileIrxHost.removeSharedJournal(tag: "t2", directory: dir.path)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }
}
