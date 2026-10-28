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
}
