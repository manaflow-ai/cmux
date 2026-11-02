import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation
import Testing
import CmuxNextTestSupport

/// A password CSV import's conflicts and the store's failures, at the
/// boundary the app writes through (cx-dwg.6, #20029 review):
/// - The fork answers a store failure with -1 counts (cef_cmux.h, API 20).
///   An import or a Replace that got one failed; it never reads as
///   "Imported: -1." or "Replaced: -1.", and never trashes the CSV as if
///   every row went in.
/// - The Replace toast pushed out by unrelated toasts still leaves the
///   Move to Trash offer for the plaintext file.
/// - A second CSV import right after the first leaves the first file's
///   offer up beside its own (cx-dwg.8, #20029 review nit).
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1)))
struct PasswordImportConflictTests {
    private static let csv = "name,url,username,password\nexample,https://example.com/login,someone,throwaway-1\n"

    private static func login() -> ImportedLogin {
        ImportedLogin(url: "https://example.com/login", signonRealm: "https://example.com/", username: "someone",
                      password: SecretBytes(copying: Array("throwaway-2".utf8)), created: nil)
    }

    @Test func anImportTheStoreFailedIsAFailureNotCounts() async {
        let destination = AppPasswordDestination(available: true) { _, _ in
            ChromiumPasswordWriteResult(added: -1, duplicate: -1, conflict: -1, rejected: -1)
        }
        let bytes = SecretBytes(copying: Array(Self.csv.utf8))
        await #expect(throws: PasswordImporter.Failure.storeUnavailable) {
            _ = try await PasswordCSVImporter(destination: destination).run(bytes: bytes, intoProfile: BrowserProfileRecord.defaultID)
        }
    }

    @Test func aReplaceTheStoreFailedIsAFailureNotCounts() async {
        let hold = PasswordConflictHold { _, _ in ChromiumPasswordReplaceResult(updated: -1, missing: -1, rejected: -1) }
        let login = Self.login()
        hold.keep([login], profile: .default)
        await #expect(throws: (any Error).self) { _ = try await hold.replace() }
        #expect(login.password.count == 0, "the held password is zeroed after the failed Replace")
    }

    @Test func aReplaceToastPushedOutByOtherToastsStillOffersTheTrash() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns it; close() would release it on top of ARC's references.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(Self.csv.utf8).write(to: file)
        let hold = PasswordConflictHold { _, _ in ChromiumPasswordReplaceResult(updated: 1, missing: 0, rejected: 0) }
        hold.keep([Self.login()], profile: .default)
        var report = PasswordImportReport()
        report.read = 1
        report.store = PasswordStoreReply(added: 0, duplicate: 0, conflict: 1, rejected: 0)

        PasswordCSVFiles.trash(file, report: report, hold: hold) { window }
        let csvToast = { CmuxToastCenter.shared.toasts(in: window).first { $0.id == PasswordCSVFiles.fileToastID(file) } }
        #expect(csvToast()?.action?.title == PasswordCSVStrings.replace)

        for index in 1...CmuxToastStack.limit {
            CmuxToastCenter.shared.show(CmuxToast(id: "unrelated-\(index)", message: "unrelated \(index)"), in: window)
        }
        for _ in 0..<50 where csvToast() == nil { await Task.yield() }
        #expect(csvToast()?.action?.title == PasswordCSVStrings.moveToTrash, "the plaintext file is still offered for the Trash")
        #expect(hold.count == 0, "the held passwords went with the Replace toast")
        #expect(FileManager.default.fileExists(atPath: file.path), "nothing trashed the file without the person")
    }

    @Test func aSecondCSVImportLeavesTheFirstFilesOffer() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; close() would release it on top of ARC's references.
        defer { window.close() }
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-\(UUID().uuidString).csv")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("rejected-\(UUID().uuidString).csv")
        defer { for file in [first, second] { try? FileManager.default.removeItem(at: file) } }
        for file in [first, second] { try Data(Self.csv.utf8).write(to: file) }
        let hold = PasswordConflictHold { _, _ in ChromiumPasswordReplaceResult(updated: 1, missing: 0, rejected: 0) }
        hold.keep([Self.login()], profile: .default)
        var conflicted = PasswordImportReport()
        conflicted.read = 1
        conflicted.store = PasswordStoreReply(added: 0, duplicate: 0, conflict: 1, rejected: 0)
        var rejected = PasswordImportReport()
        rejected.read = 1
        rejected.store = PasswordStoreReply(added: 0, duplicate: 0, conflict: 0, rejected: 1)

        PasswordCSVFiles.trash(first, report: conflicted, hold: hold) { window }
        PasswordCSVFiles.trash(second, report: rejected) { window }
        for _ in 0..<50 { await Task.yield() }

        let offers = CmuxToastCenter.shared.toasts(in: window).filter { $0.id.hasPrefix(PasswordCSVFiles.toastID) }
        #expect(offers.compactMap(\.action?.title).sorted() == [PasswordCSVStrings.moveToTrash, PasswordCSVStrings.replace].sorted(),
                "each plaintext file keeps its own offer: \(offers.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    }
}
